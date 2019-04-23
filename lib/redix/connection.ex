defmodule Redix.Connection do
  @moduledoc false

  alias Redix.{ConnectionError, Protocol, SocketOwner, StartOptions, Telemetry}

  @behaviour :gen_statem

  defstruct [
    :opts,
    :transport,
    :socket_owner,
    :table,
    :socket,
    :backoff_current,
    :connected_address,
    counter: 0,
    client_reply: :on
  ]

  @backoff_exponent 1.5

  ## Public API

  def start_link(opts) when is_list(opts) do
    opts = StartOptions.sanitize(opts)

    case Keyword.pop(opts, :name) do
      {nil, opts} ->
        :gen_statem.start_link(__MODULE__, opts, [])

      {atom, opts} when is_atom(atom) ->
        :gen_statem.start_link({:local, atom}, __MODULE__, opts, [])

      {{:global, _term} = tuple, opts} ->
        :gen_statem.start_link(tuple, __MODULE__, opts, [])

      {{:via, via_module, _term} = tuple, opts} when is_atom(via_module) ->
        :gen_statem.start_link(tuple, __MODULE__, opts, [])

      {other, _opts} ->
        raise ArgumentError, """
        expected :name option to be one of the following:

          * nil
          * atom
          * {:global, term}
          * {:via, module, term}

        Got: #{inspect(other)}
        """
    end
  end

  def stop(conn, timeout) do
    :gen_statem.stop(conn, :normal, timeout)
  end

  def pipeline(conn, commands, timeout) do
    request_id = Process.monitor(conn)

    # We cast to the connection process knowing that it will reply at some point,
    # either after roughly timeout or when a response is ready.
    cast = {:pipeline, commands, _from = {self(), request_id}, timeout}
    :ok = :gen_statem.cast(GenServer.whereis(conn), cast)

    receive do
      {^request_id, resp} ->
        _ = Process.demonitor(request_id, [:flush])
        resp

      {:DOWN, ^request_id, _, _, reason} ->
        exit(reason)
    end
  end

  ## Callbacks

  ## Init callbacks

  @impl true
  def callback_mode(), do: :state_functions

  @impl true
  def init(opts) do
    transport = if(opts[:ssl], do: :ssl, else: :gen_tcp)
    queue_table = :ets.new(:queue, [:ordered_set, :public])
    {:ok, socket_owner} = SocketOwner.start_link(self(), opts, queue_table)

    data = %__MODULE__{
      opts: opts,
      table: queue_table,
      socket_owner: socket_owner,
      transport: transport
    }

    if opts[:sync_connect] do
      # We don't need to handle a timeout here because we're using a timeout in
      # connect/3 down the pipe.
      receive do
        {:connected, ^socket_owner, socket, address} ->
          {:ok, :connected, %__MODULE__{data | socket: socket, connected_address: address}}

        {:stopped, ^socket_owner, reason} ->
          {:stop, %Redix.ConnectionError{reason: reason}}
      end
    else
      {:ok, :connecting, data}
    end
  end

  @impl true
  def terminate(reason, _state, data) do
    if Process.alive?(data.socket_owner) and reason == :normal do
      :ok = SocketOwner.normal_stop(data.socket_owner)
    end
  end

  ## State functions

  # "Disconnected" state: the connection is down and the socket owner is not alive.

  # We want to connect/reconnect. We start the socket owner process and then go in the :connecting
  # state.
  def disconnected({:timeout, :reconnect}, _timer_info, %__MODULE__{} = data) do
    {:ok, socket_owner} = SocketOwner.start_link(self(), data.opts, data.table)
    new_data = %{data | socket_owner: socket_owner}
    {:next_state, :connecting, new_data}
  end

  def disconnected({:timeout, {:client_timed_out, _counter}}, _from, _data) do
    :keep_state_and_data
  end

  def disconnected(:internal, {:notify_of_disconnection, _reason}, %__MODULE__{table: table}) do
    fun = fn {_counter, from, _ncommands, timed_out?}, _acc ->
      if not timed_out?, do: reply(from, {:error, %ConnectionError{reason: :disconnected}})
    end

    :ets.foldl(fun, nil, table)
    :ets.delete_all_objects(table)

    :keep_state_and_data
  end

  def disconnected(:cast, {:pipeline, _commands, from, _timeout}, _data) do
    reply(from, {:error, %ConnectionError{reason: :closed}})
    :keep_state_and_data
  end

  # This happens when there's a send error. We close the socket right away, but we wait for
  # the socket owner to die so that it can finish processing the data it's processing. When it's
  # dead, we go ahead and notify the remaining clients, setup backoff, and so on.
  def disconnected(:info, {:stopped, owner, reason}, %__MODULE__{socket_owner: owner} = data) do
    Telemetry.execute(:disconnection, %{
      address: data.connected_address,
      reason: %ConnectionError{reason: reason}
    })

    data = %{data | connected_address: nil}
    disconnect(data, reason)
  end

  def connecting(
        :info,
        {:connected, owner, socket, address},
        %__MODULE__{socket_owner: owner} = data
      ) do
    if data.backoff_current do
      Telemetry.execute(:reconnected, %{address: address})
    end

    data = %{data | socket: socket, backoff_current: nil, connected_address: address}
    {:next_state, :connected, %{data | socket: socket}}
  end

  def connecting(:cast, {:pipeline, _commands, _from, _timeout}, _data) do
    {:keep_state_and_data, :postpone}
  end

  def connecting(:info, {:stopped, owner, reason}, %__MODULE__{socket_owner: owner} = data) do
    # We log this when the socket owner stopped while connecting.
    Telemetry.execute(:failed_connection, %{
      address: format_address(data),
      reason: %ConnectionError{reason: reason}
    })

    disconnect(data, reason)
  end

  def connecting({:timeout, {:client_timed_out, _counter}}, _from, _data) do
    :keep_state_and_data
  end

  def connected(:cast, {:pipeline, commands, from, timeout}, data) do
    {ncommands, data} = get_client_reply(data, commands)

    if ncommands > 0 do
      {counter, data} = get_and_update_in(data.counter, &{&1, &1 + 1})

      row = {counter, from, ncommands, _timed_out? = false}
      :ets.insert(data.table, row)

      case data.transport.send(data.socket, Enum.map(commands, &Protocol.pack/1)) do
        :ok ->
          actions =
            case timeout do
              :infinity -> []
              _other -> [{{:timeout, {:client_timed_out, counter}}, timeout, from}]
            end

          {:keep_state, data, actions}

        {:error, _reason} ->
          # The socket owner will get a closed message at some point, so we just move to the
          # disconnected state.
          :ok = data.transport.close(data.socket)
          {:next_state, :disconnected, data}
      end
    else
      reply(from, {:ok, []})
      {:keep_state, data}
    end
  end

  def connected(:info, {:stopped, owner, reason}, %__MODULE__{socket_owner: owner} = data) do
    Telemetry.execute(:disconnection, %{
      address: data.connected_address,
      reason: %ConnectionError{reason: reason}
    })

    data = %{data | connected_address: nil}
    disconnect(data, reason)
  end

  def connected({:timeout, {:client_timed_out, counter}}, from, %__MODULE__{} = data) do
    if _found? = :ets.update_element(data.table, counter, {4, _timed_out? = true}) do
      reply(from, {:error, %ConnectionError{reason: :timeout}})
    end

    :keep_state_and_data
  end

  ## Helpers

  defp reply({pid, request_id} = _from, reply) do
    send(pid, {request_id, reply})
  end

  defp disconnect(_data, %Redix.Error{} = error) do
    {:stop, error}
  end

  defp disconnect(data, reason) do
    if data.opts[:exit_on_disconnection] do
      {:stop, %ConnectionError{reason: reason}}
    else
      {backoff, data} = next_backoff(data)

      actions = [
        {:next_event, :internal, {:notify_of_disconnection, reason}},
        {{:timeout, :reconnect}, backoff, nil}
      ]

      {:next_state, :disconnected, data, actions}
    end
  end

  defp next_backoff(%__MODULE__{backoff_current: nil} = data) do
    backoff_initial = data.opts[:backoff_initial]
    {backoff_initial, %{data | backoff_current: backoff_initial}}
  end

  defp next_backoff(data) do
    next_exponential_backoff = round(data.backoff_current * @backoff_exponent)

    backoff_current =
      if data.opts[:backoff_max] == :infinity do
        next_exponential_backoff
      else
        min(next_exponential_backoff, Keyword.fetch!(data.opts, :backoff_max))
      end

    {backoff_current, %{data | backoff_current: backoff_current}}
  end

  defp get_client_reply(data, commands) do
    {ncommands, client_reply} = get_client_reply(commands, _ncommands = 0, data.client_reply)
    {ncommands, put_in(data.client_reply, client_reply)}
  end

  defp get_client_reply([], ncommands, client_reply) do
    {ncommands, client_reply}
  end

  defp get_client_reply([command | rest], ncommands, client_reply) do
    case parse_client_reply(command) do
      :off -> get_client_reply(rest, ncommands, :off)
      :skip when client_reply == :off -> get_client_reply(rest, ncommands, :off)
      :skip -> get_client_reply(rest, ncommands, :skip)
      :on -> get_client_reply(rest, ncommands + 1, :on)
      nil when client_reply == :on -> get_client_reply(rest, ncommands + 1, client_reply)
      nil when client_reply == :off -> get_client_reply(rest, ncommands, client_reply)
      nil when client_reply == :skip -> get_client_reply(rest, ncommands, :on)
    end
  end

  defp parse_client_reply(["CLIENT", "REPLY", "ON"]), do: :on
  defp parse_client_reply(["CLIENT", "REPLY", "OFF"]), do: :off
  defp parse_client_reply(["CLIENT", "REPLY", "SKIP"]), do: :skip
  defp parse_client_reply(["client", "reply", "on"]), do: :on
  defp parse_client_reply(["client", "reply", "off"]), do: :off
  defp parse_client_reply(["client", "reply", "skip"]), do: :skip

  defp parse_client_reply([part1, part2, part3])
       when is_binary(part1) and is_binary(part2) and is_binary(part3) do
    case [String.upcase(part1), String.upcase(part2), String.upcase(part3)] do
      ["CLIENT", "REPLY", "ON"] -> :on
      ["CLIENT", "REPLY", "OFF"] -> :off
      ["CLIENT", "REPLY", "SKIP"] -> :skip
      _other -> nil
    end
  end

  defp parse_client_reply(_other), do: nil

  defp format_address(%{opts: opts} = _state) do
    if opts[:sentinel] do
      "sentinel"
    else
      "#{opts[:host]}:#{opts[:port]}"
    end
  end
end
