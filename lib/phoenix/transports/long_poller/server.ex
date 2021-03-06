defmodule Phoenix.Transports.LongPoller.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    children = [
      worker(Phoenix.Transports.LongPoller.Server, [], restart: :transient)
    ]
    supervise(children, strategy: :simple_one_for_one)
  end
end

defmodule Phoenix.Transports.LongPoller.Server do
  use GenServer

  @moduledoc false

  alias Phoenix.Socket.Message
  alias Phoenix.Channel.Transport
  alias Phoenix.Transports.LongPoller
  alias Phoenix.PubSub

  @doc """
  Starts the Server.

    * `router` - The router module, ie. `MyApp.Router`
    * `window_ms` - The longpoll session timeout, in milliseconds

  If the server receives no message within `window_ms`, it terminates and
  clients are responsible for opening a new session.
  """
  def start_link(router, window_ms, priv_topic, pubsub_server) do
    GenServer.start_link(__MODULE__, [router, window_ms, priv_topic, pubsub_server])
  end

  @doc false
  def init([router, window_ms, priv_topic, pubsub_server]) do
    Process.flag(:trap_exit, true)

    state = %{buffer: [],
              router: router,
              sockets: HashDict.new,
              sockets_inverse: HashDict.new,
              window_ms: window_ms * 2,
              pubsub_server: Process.whereis(pubsub_server),
              priv_topic: priv_topic,
              client_ref: nil}

    :ok = PubSub.subscribe(state.pubsub_server, self, state.priv_topic, link: true)
    {:ok, state, state.window_ms}
  end

  @doc """
  Stops the server
  """
  def handle_call(:stop, _from, state), do: {:stop, :shutdown, :ok, state}

  @doc """
  Dispatches client `%Phoenix.Socket.Messages{}` back through Transport layer.
  """
  def handle_info({:dispatch, msg, ref}, state) do
    msg
    |> Transport.dispatch(state.sockets, self, state.router, state.pubsub_server, LongPoller)
    |> case do
      {:ok, socket_pid} ->
        :ok = broadcast_from(state, {:ok, :dispatch, ref})

        new_state = %{state | sockets: HashDict.put(state.sockets, msg.topic, socket_pid),
                              sockets_inverse: HashDict.put(state.sockets_inverse, socket_pid, msg.topic)}
        {:noreply, new_state, state.window_ms}
      :ok ->
        :ok = broadcast_from(state, {:ok, :dispatch, ref})
        {:noreply, state, state.window_ms}
      {:error, reason} ->
        :ok = broadcast_from(state, {:error, :dispatch, reason, ref})
        {:noreply, state, state.window_ms}
      :ignore ->
        :ok = broadcast_from(state, {:error, :dispatch, :ignore, ref})
        {:noreply, state, state.window_ms}
    end
  end

  @doc """
  Forwards replied/broadcasted `%Phoenix.Socket.Message{}`s from Channels back to client.
  """
  def handle_info({:socket_reply, msg}, state) do
    publish_reply(msg, state)
  end

  @doc """
  Crash if pubsub adapter goes down
  """
  def handle_info({:EXIT, pub_pid, :shutdown}, %{pubsub_server: pub_pid} = state) do
    {:stop, :pubsub_server_terminated, state}
  end

  @doc """
  Trap channel process exits and notify client of close or error events

  `:normal` exits indicate the channel shutdown gracefully from a `{:leave, socket}`
   return. Any other exit reason is treated as an error.
  """
  def handle_info({:EXIT, socket_pid, reason}, state) do
    case HashDict.get(state.sockets_inverse, socket_pid) do
      nil   -> {:noreply, state, state.window_ms}
      topic ->
        new_state = %{state | sockets: HashDict.delete(state.sockets, topic),
                              sockets_inverse: HashDict.delete(state.sockets_inverse, socket_pid)}
        case reason do
          :normal ->
            publish_reply(%Message{topic: topic, event: "chan:close", payload: %{}}, new_state)
          _other ->
            publish_reply(%Message{topic: topic, event: "chan:error", payload: %{}}, new_state)
        end
    end
  end

  def handle_info({:subscribe, ref}, state) do
    :ok = broadcast_from(state, {:ok, :subscribe, ref})

    {:noreply, state, state.window_ms}
  end

  def handle_info({:flush, ref}, state) do
    if Enum.any?(state.buffer) do
      :ok = broadcast_from(state, {:messages, Enum.reverse(state.buffer), ref})
    end
    {:noreply, %{state | client_ref: ref}, state.window_ms}
  end

  # TODO: %Messages{}'s need unique ids so we can properly ack them
  @doc """
  Handles acknowledged messages from client and removes from buffer.
  `:ack` calls to the server also represent the client listener
  closing for repoll.
  """
  def handle_info({:ack, msg_count, ref}, state) do
    buffer = Enum.drop(state.buffer, -msg_count)
    :ok = broadcast_from(state, {:ok, :ack, ref})

    {:noreply, %{state | buffer: buffer}, state.window_ms}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @doc """
  Handles forwarding arbitrary Elixir messages back to listening client
  """
  # TODO figure out if dispatch_leave is still needed
  def terminate(reason, state) do
    :ok = Transport.dispatch_leave(state.sockets, reason)
    :ok
  end

  defp broadcast_from(state, msg) do
    PubSub.broadcast_from(state.pubsub_server, self, state.priv_topic, msg)
  end

  defp publish_reply(msg, state) do
    buffer = [msg | state.buffer]
    if state.client_ref do
      :ok = broadcast_from(state, {:messages, Enum.reverse(buffer), state.client_ref})
    end

    {:noreply, %{state | buffer: buffer}, state.window_ms}
  end
end
