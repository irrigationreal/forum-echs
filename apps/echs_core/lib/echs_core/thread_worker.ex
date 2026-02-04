defmodule EchsCore.ThreadWorker do
  @moduledoc """
  GenServer managing a single conversation thread.
  Handles the full tool loop, sub-agents, and state.
  """

  use GenServer
  require Logger

  alias EchsCore.{Blackboard, ModelInfo}
  alias EchsCore.ThreadWorker.Config, as: TWConfig
  alias EchsCore.ThreadWorker.HistoryManager, as: TWHistory
  alias EchsCore.ThreadWorker.Persistence, as: TWPersist
  alias EchsCore.ThreadWorker.StreamRunner, as: TWStream
  alias EchsCore.ThreadWorker.ToolDispatch, as: TWDispatch

  # Time to wait for a polite stream interrupt before force-killing the stream task.
  @interrupt_force_kill_ms 10_000

  defstruct [
    :thread_id,
    :parent_thread_id,
    :created_at_ms,
    :last_activity_at_ms,
    :model,
    :reasoning,
    :cwd,
    :instructions,
    :tools,
    :history_items,
    :status,
    :current_message_id,
    :current_turn_started_at_ms,
    :last_usage,
    :last_usage_at_ms,
    :message_ids,
    :message_id_set,
    :message_log,
    :children,
    :coordination_mode,
    :blackboard,
    :stream_ref,
    :stream_pid,
    :stream_monitor,
    :reply_to,
    :pending_interrupts,
    :queued_turns,
    :resume_turns,
    :steer_queue,
    :tool_handlers,
    :current_slot_ref,
    :pending_slot_ref,
    :shell_path,
    :shell_snapshot_path,
    :shell_session_id,
    :shell_session_cwd,
    :shell_session_login,
    :tool_task_ref,
    :tool_task_pid,
    :tool_task_monitor,
    :trace_id,
    :pending_agent_spawns
  ]

  @type thread_id :: String.t()
  @type history_item :: map()
  @type tool_handler ::
          (map(), map() -> term())
          | (map() -> term())
          | {module(), atom()}
          | {module(), atom(), [term()]}
  @type child_info :: %{pid: pid() | nil, monitor_ref: reference() | nil}
  @type queued_turn :: %{
          from: GenServer.from() | nil,
          content: String.t() | [map()],
          opts: keyword(),
          message_id: String.t(),
          enqueued_at_ms: non_neg_integer()
        }

  @type message_status :: :queued | :running | :completed | :interrupted | :paused | :error

  @type message_meta :: %{
          message_id: String.t(),
          status: message_status(),
          enqueued_at_ms: non_neg_integer() | nil,
          started_at_ms: non_neg_integer() | nil,
          completed_at_ms: non_neg_integer() | nil,
          history_start: non_neg_integer() | nil,
          history_end: non_neg_integer() | nil,
          error: term() | nil
        }

  @type steer_turn :: %{
          from: GenServer.from() | nil,
          content: String.t() | [map()],
          opts: keyword(),
          message_id: String.t(),
          enqueued_at_ms: non_neg_integer(),
          preserve_reply?: boolean()
        }
  @type state :: %__MODULE__{
          thread_id: thread_id(),
          parent_thread_id: thread_id() | nil,
          created_at_ms: non_neg_integer(),
          last_activity_at_ms: non_neg_integer(),
          model: String.t(),
          reasoning: String.t(),
          cwd: String.t(),
          instructions: String.t(),
          tools: list(map()),
          history_items: [history_item()],
          status: :idle | :running | :paused,
          current_message_id: String.t() | nil,
          current_turn_started_at_ms: non_neg_integer() | nil,
          message_ids: [String.t()],
          message_id_set: MapSet.t(),
          message_log: %{optional(String.t()) => message_meta()},
          children: %{optional(thread_id()) => child_info()},
          coordination_mode: :hierarchical | :blackboard | :peer,
          blackboard: pid(),
          stream_ref: reference() | nil,
          stream_pid: pid() | nil,
          stream_monitor: reference() | nil,
          reply_to: GenServer.from() | nil,
          pending_interrupts: [GenServer.from()],
          queued_turns: [queued_turn()],
          resume_turns: [queued_turn()],
          steer_queue: [steer_turn()],
          tool_handlers: %{optional(String.t()) => tool_handler()},
          current_slot_ref: reference() | nil,
          pending_slot_ref: reference() | nil,
          shell_path: String.t() | nil,
          shell_snapshot_path: String.t() | nil,
          shell_session_id: String.t() | nil,
          shell_session_cwd: String.t() | nil,
          shell_session_login: boolean() | nil
        }

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(thread_id))
  end

  @spec via_tuple(thread_id()) :: {:via, Registry, {EchsCore.Registry, thread_id()}}
  def via_tuple(thread_id) do
    {:via, Registry, {EchsCore.Registry, thread_id}}
  end

  @doc """
  Create a new thread.
  """
  @spec create(keyword()) :: {:ok, thread_id()} | {:error, term()}
  def create(opts \\ []) do
    thread_id = Keyword.get(opts, :thread_id, generate_id())
    opts = Keyword.put(opts, :thread_id, thread_id)

    case DynamicSupervisor.start_child(EchsCore.ThreadSupervisor, {__MODULE__, opts}) do
      {:ok, _pid} -> {:ok, thread_id}
      error -> error
    end
  end

  @doc """
  Send a user message and start a turn.

  Options:
    - :mode - :queue (default) or :steer. When running, :queue enqueues and :steer preempts.
    - :steer - legacy boolean, treated as :mode => :steer.
    - :configure - config map to apply for this turn.
  """
  @spec send_message(thread_id(), String.t() | [map()], keyword()) ::
          {:ok, [history_item()]} | {:error, term()}
  def send_message(thread_id, content, opts \\ []) do
    GenServer.call(via_tuple(thread_id), {:send_message, content, opts}, :infinity)
  end

  @doc """
  Enqueue a user message and start a turn asynchronously.

  This call returns immediately with a `message_id`. Turn progress and results
  are surfaced via PubSub events (and the server's SSE endpoint).

  Options:
    - :mode - :queue (default) or :steer. When running, :queue enqueues and :steer preempts.
    - :configure - config map to apply for this turn.
    - :message_id - optional caller-provided message id (useful for idempotency).
  """
  @spec enqueue_message(thread_id(), String.t() | [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def enqueue_message(thread_id, content, opts \\ []) do
    GenServer.call(via_tuple(thread_id), {:enqueue_message, content, opts})
  end

  @doc """
  List known message ids for this thread, newest-first.

  Options:
    - `:limit` (default: 50)
  """
  @spec list_messages(thread_id(), keyword()) :: [message_meta()]
  def list_messages(thread_id, opts \\ []) do
    GenServer.call(via_tuple(thread_id), {:list_messages, opts})
  end

  @doc """
  Fetch a single message metadata entry.
  """
  @spec get_message(thread_id(), String.t()) :: {:ok, message_meta()} | {:error, :not_found}
  def get_message(thread_id, message_id) do
    GenServer.call(via_tuple(thread_id), {:get_message, message_id})
  end

  @doc """
  Return a slice of thread history items.

  Options:
    - `:offset` (default: 0)
    - `:limit` (default: 200)
  """
  @spec get_history(thread_id(), keyword()) ::
          {:ok,
           %{
             total: non_neg_integer(),
             offset: non_neg_integer(),
             limit: non_neg_integer(),
             items: [map()]
           }}
  def get_history(thread_id, opts \\ []) do
    GenServer.call(via_tuple(thread_id), {:get_history, opts})
  end

  @doc """
  Return the history items associated with a single message_id.

  If the message is still running, `history_end` is treated as the current
  history length.
  """
  @spec get_message_items(thread_id(), String.t(), keyword()) ::
          {:ok, %{message: message_meta(), items: [map()]}} | {:error, :not_found}
  def get_message_items(thread_id, message_id, opts \\ []) do
    GenServer.call(via_tuple(thread_id), {:get_message_items, message_id, opts})
  end

  @doc """
  Configure thread settings (hot-swap).
  """
  @spec configure(thread_id(), map()) :: :ok
  def configure(thread_id, config) do
    GenServer.call(via_tuple(thread_id), {:configure, config})
  end

  @doc """
  Register a custom tool for this thread.
  """
  @spec add_tool(thread_id(), map(), tool_handler()) :: :ok | {:error, term()}
  def add_tool(thread_id, spec, handler) do
    GenServer.call(via_tuple(thread_id), {:add_tool, spec, handler})
  end

  @doc """
  Remove a custom tool from this thread.
  """
  @spec remove_tool(thread_id(), String.t()) :: :ok
  def remove_tool(thread_id, name) do
    GenServer.call(via_tuple(thread_id), {:remove_tool, name})
  end

  @doc """
  Get thread state.
  """
  @spec get_state(thread_id()) :: state()
  def get_state(thread_id) do
    GenServer.call(via_tuple(thread_id), :get_state)
  end

  @doc """
  Pause the thread.
  """
  @spec pause(thread_id()) :: :ok
  def pause(thread_id) do
    GenServer.call(via_tuple(thread_id), :pause)
  end

  @doc """
  Resume the thread.
  """
  @spec resume(thread_id()) :: :ok
  def resume(thread_id) do
    GenServer.call(via_tuple(thread_id), :resume)
  end

  @doc """
  Interrupt current turn.
  """
  @spec interrupt(thread_id()) :: :ok
  def interrupt(thread_id) do
    GenServer.call(via_tuple(thread_id), :interrupt)
  end

  @doc """
  Kill the thread and all children.
  """
  @spec kill(thread_id()) :: :ok
  def kill(thread_id) do
    GenServer.stop(via_tuple(thread_id), :killed)
  end

  @doc """
  Subscribe to thread events.
  """
  @spec subscribe(thread_id()) :: :ok | {:error, term()}
  def subscribe(thread_id) do
    Phoenix.PubSub.subscribe(EchsCore.PubSub, "thread:#{thread_id}")
  end

  if Mix.env() == :test do
    @doc false
    def test_apply_sse_events(thread_id, events) when is_list(events) do
      GenServer.call(via_tuple(thread_id), {:test_sse_events, events})
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    parent_thread_id = Keyword.get(opts, :parent_thread_id)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    now_ms = now_ms()

    created_at_ms = Keyword.get(opts, :created_at_ms, now_ms)
    last_activity_at_ms = Keyword.get(opts, :last_activity_at_ms, created_at_ms)

    history_items = Keyword.get(opts, :history_items, [])
    message_log = Keyword.get(opts, :message_log, %{})
    message_ids = Keyword.get(opts, :message_ids, Map.keys(message_log))

    queued_turns = Keyword.get(opts, :queued_turns, [])
    steer_queue = Keyword.get(opts, :steer_queue, [])

    # Create thread-local blackboard
    {:ok, blackboard} = Blackboard.start_link([])

    # Subscribe to blackboard events scoped to this thread. Children broadcast
    # on "blackboard:#{parent_thread_id}" so only the parent receives them.
    :ok = Phoenix.PubSub.subscribe(EchsCore.PubSub, "blackboard:#{thread_id}")

    model = Keyword.get(opts, :model, "gpt-5.2-codex")

    shell_path = System.get_env("SHELL") || "/bin/bash"

    shell_snapshot_path =
      case EchsCore.Tools.ShellSnapshot.ensure_snapshot(shell_path, thread_id) do
        {:ok, path} -> path
        _ -> nil
      end

    state = %__MODULE__{
      thread_id: thread_id,
      parent_thread_id: parent_thread_id,
      created_at_ms: created_at_ms,
      last_activity_at_ms: last_activity_at_ms,
      model: model,
      reasoning: ModelInfo.normalize_reasoning(Keyword.get(opts, :reasoning, "medium")),
      cwd: cwd,
      instructions: TWConfig.build_instructions(Keyword.get(opts, :instructions), cwd, parent_thread_id: parent_thread_id),
      tools: Keyword.get(opts, :tools, TWConfig.default_tools(model)),
      history_items: history_items,
      status: :idle,
      current_message_id: nil,
      current_turn_started_at_ms: nil,
      last_usage: Keyword.get(opts, :last_usage, nil),
      last_usage_at_ms: Keyword.get(opts, :last_usage_at_ms, nil),
      message_ids: message_ids,
      message_id_set: MapSet.new(message_ids),
      message_log: message_log,
      children: %{},
      coordination_mode: Keyword.get(opts, :coordination_mode, :hierarchical),
      blackboard: blackboard,
      stream_ref: nil,
      stream_pid: nil,
      stream_monitor: nil,
      reply_to: nil,
      pending_interrupts: [],
      queued_turns: queued_turns,
      resume_turns: Keyword.get(opts, :resume_turns, []),
      steer_queue: steer_queue,
      tool_handlers: %{},
      current_slot_ref: nil,
      pending_slot_ref: nil,
      shell_path: shell_path,
      shell_snapshot_path: shell_snapshot_path,
      pending_agent_spawns: :queue.new()
    }

    broadcast(state, :thread_created, %{thread_id: thread_id, config: TWPersist.config_summary(state)})

    _ = TWPersist.persist_thread(state)

    if state.resume_turns != [] or state.queued_turns != [] or state.steer_queue != [] do
      send(self(), :auto_start_queued)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, _content, _opts}, _from, %{status: :paused} = state) do
    {:reply, {:error, :paused}, state}
  end

  @impl true
  def handle_call({:enqueue_message, _content, _opts}, _from, %{status: :paused} = state) do
    {:reply, {:error, :paused}, state}
  end

  def handle_call({:enqueue_message, content, opts}, _from, %{status: :running} = state) do
    mode = send_mode(opts)
    message_id = message_id_for_turn(state, opts)
    request_json = encode_message_request(content, opts, mode)

    if MapSet.member?(state.message_id_set, message_id) do
      {:reply, {:ok, message_id}, touch(state)}
    else
      state =
        state
        |> remember_message_id(message_id)
        |> message_log_enqueue(message_id, request_json)

      _ = TWPersist.persist_message(state, message_id)

      state =
        case mode do
          :steer -> enqueue_steer(state, nil, content, opts, message_id, preserve_reply?: false)
          _ -> enqueue_turn(state, nil, content, opts, message_id)
        end

      state =
        case mode do
          :steer -> request_stream_control(state, :steer)
          _ -> state
        end

      {:reply, {:ok, message_id}, state}
    end
  end

  def handle_call({:enqueue_message, content, opts}, _from, state) do
    message_id = message_id_for_turn(state, opts)
    request_json = encode_message_request(content, opts, :queue)

    if MapSet.member?(state.message_id_set, message_id) do
      {:reply, {:ok, message_id}, touch(state)}
    else
      state =
        state
        |> remember_message_id(message_id)
        |> message_log_enqueue(message_id, request_json)
        |> begin_turn(message_id)
        |> TWConfig.apply_turn_config(opts)
        |> add_user_message(content)

      _ = TWPersist.persist_message(state, message_id)

      broadcast(state, :turn_started, %{thread_id: state.thread_id})
      state = start_stream(state)

      {:reply, {:ok, message_id}, state}
    end
  end

  @impl true
  def handle_call({:send_message, content, opts}, from, %{status: :running} = state) do
    mode = send_mode(opts)
    message_id = message_id_for_turn(state, opts)
    request_json = encode_message_request(content, opts, mode)

    state =
      state
      |> remember_message_id(message_id)
      |> message_log_enqueue(message_id, request_json)

    _ = TWPersist.persist_message(state, message_id)

    state =
      case mode do
        :steer -> enqueue_steer(state, from, content, opts, message_id, preserve_reply?: false)
        _ -> enqueue_turn(state, from, content, opts, message_id)
      end

    state =
      case mode do
        :steer -> request_stream_control(state, :steer)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_call({:send_message, content, opts}, from, state) do
    message_id = message_id_for_turn(state, opts)
    request_json = encode_message_request(content, opts, :queue)

    state =
      state
      |> remember_message_id(message_id)
      |> message_log_enqueue(message_id, request_json)
      |> begin_turn(message_id)
      |> TWConfig.apply_turn_config(opts)
      |> add_user_message(content)

    _ = TWPersist.persist_message(state, message_id)

    broadcast(state, :turn_started, %{thread_id: state.thread_id})

    state =
      state
      |> Map.put(:reply_to, from)
      |> start_stream()

    {:noreply, state}
  end

  @impl true
  def handle_call({:configure, config}, _from, state) do
    state =
      state
      |> TWConfig.apply_config(config)
      |> touch()

    _ = TWPersist.persist_thread(state)

    broadcast(state, :thread_configured, %{thread_id: state.thread_id, changes: config})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_tool, spec, handler}, _from, state) do
    case TWConfig.normalize_tool_spec(spec) do
      {:ok, normalized, name} ->
        state = %{
          state
          | tools: TWConfig.uniq_tools(state.tools ++ [normalized]),
            tool_handlers: Map.put(state.tool_handlers, name, handler)
        }

        _ = TWPersist.persist_thread(state)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_tool, name}, _from, state) do
    name = to_string(name)

    state = %{
      state
      | tools: TWConfig.remove_tool_spec(state.tools, name),
        tool_handlers: Map.delete(state.tool_handlers, name)
    }

    _ = TWPersist.persist_thread(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:list_messages, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50) |> clamp_int(1, 500)

    messages =
      state.message_ids
      |> Enum.reverse()
      |> Enum.take(limit)
      |> Enum.map(fn id -> Map.get(state.message_log, id) end)
      |> Enum.reject(&is_nil/1)

    {:reply, messages, state}
  end

  @impl true
  def handle_call({:get_message, message_id}, _from, state) do
    message_id = to_string(message_id)

    case Map.fetch(state.message_log, message_id) do
      {:ok, meta} -> {:reply, {:ok, meta}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    offset = Keyword.get(opts, :offset, 0) |> clamp_int(0, 1_000_000_000)
    limit = Keyword.get(opts, :limit, 200) |> clamp_int(1, 2_000)

    total = length(state.history_items)

    items =
      state.history_items
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, {:ok, %{total: total, offset: offset, limit: limit, items: items}}, state}
  end

  if Mix.env() == :test do
    def handle_call({:test_sse_events, events}, _from, state) when is_list(events) do
      {:ok, items_agent} = Agent.start_link(fn -> [] end)
      Process.put(:reasoning_delta_seen, false)
      ctx = %{thread_id: state.thread_id, current_message_id: state.current_message_id}

      Enum.each(events, fn event ->
        TWStream.handle_sse_event_for_test(ctx, event, items_agent)
      end)

      items = Agent.get(items_agent, & &1)
      Agent.stop(items_agent)

      {:reply, {:ok, items}, state}
    end
  end

  @impl true
  def handle_call({:get_message_items, message_id, _opts}, _from, state) do
    message_id = to_string(message_id)

    case Map.fetch(state.message_log, message_id) do
      {:ok, meta} ->
        items =
          if is_integer(meta.history_start) do
            start_i = meta.history_start
            end_i = meta.history_end || length(state.history_items)

            state.history_items
            |> Enum.drop(start_i)
            |> Enum.take(max(end_i - start_i, 0))
          else
            []
          end

        {:reply, {:ok, %{message: meta, items: items}}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:pause, _from, state) do
    state = cancel_stream(state, :paused, reply?: true)
    {:reply, :ok, %{state | status: :paused}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    state = touch(%{state | status: :idle})
    {:reply, :ok, start_next_turn(state)}
  end

  @impl true
  def handle_call(:interrupt, from, state) do
    cond do
      state.stream_pid ->
        state = request_stream_control(state, :interrupt)
        state = %{state | pending_interrupts: [from | state.pending_interrupts]}
        # If the stream is stuck in an HTTP call, the polite control message will
        # never be read.  Schedule a forced kill as a backstop.
        Process.send_after(self(), {:interrupt_timeout, state.stream_ref}, @interrupt_force_kill_ms)
        {:noreply, state}

      state.current_message_id != nil ->
        state = cancel_stream(state, :interrupted, reply?: true)
        {:reply, :ok, %{state | status: :idle}}

      true ->
        {:reply, :ok, touch(%{state | status: :idle})}
    end
  end

  @impl true
  def handle_info({:blackboard_set, _key, _value, by, steer_message}, state) do
    # A child wrote to the global blackboard with `notify_parent: true`.
    #
    # Because the blackboard topic is global, we only act on notifications that
    # come from threads we actually spawned.
    should_handle? =
      is_binary(steer_message) and steer_message != "" and Map.has_key?(state.children, by)

    if state.status == :running and state.stream_pid != nil and should_handle? do
      content = "[Sub-agent #{by}]: #{steer_message}"

      state =
        state
        |> enqueue_steer(nil, content, [], state.current_message_id, preserve_reply?: true)
        |> request_stream_control(:steer)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:auto_start_queued, state) do
    {:noreply, start_next_turn(state)}
  end

  @impl true
  def handle_info({:turn_slot_granted, ref}, state) do
    cond do
      state.pending_slot_ref != ref ->
        {:noreply, state}

      state.status == :paused ->
        EchsCore.TurnLimiter.release(ref)
        {:noreply, %{state | pending_slot_ref: nil}}

      state.current_message_id == nil ->
        EchsCore.TurnLimiter.release(ref)
        {:noreply, %{state | pending_slot_ref: nil}}

      state.stream_pid != nil ->
        {:noreply, %{state | pending_slot_ref: nil, current_slot_ref: ref}}

      true ->
        state = %{state | pending_slot_ref: nil, current_slot_ref: ref}
        {:noreply, start_stream(state)}
    end
  end

  @impl true
  def handle_info({:interrupt_timeout, ref}, state) do
    # The polite stream control didn't work within the deadline.
    # Force-kill the stream task; the :DOWN handler will clean up,
    # mark the message as error, and reply to pending interrupt waiters.
    if ref == state.stream_ref and state.stream_pid != nil do
      Logger.warning(
        "interrupt timeout, force-killing stream thread_id=#{state.thread_id} " <>
          "message_id=#{state.current_message_id}"
      )

      Process.exit(state.stream_pid, :kill)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:usage_update, usage}, state) do
    state = %{state | last_usage: usage, last_usage_at_ms: now_ms()}
    broadcast(state, :turn_usage, %{thread_id: state.thread_id, usage: usage})
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_complete, ref, result, collected_items}, state) do
    if ref == state.stream_ref do
      state = clear_stream(state)

      case result do
        {:ok, _} ->
          tool_calls =
            Enum.filter(collected_items, fn item ->
              item["type"] in ["function_call", "local_shell_call", "custom_tool_call"]
            end)

          {normalized_items, assistant_events} =
            TWStream.normalize_assistant_items(collected_items, tool_calls == [])

          state = TWHistory.append_history_items(state, normalized_items)
          ctx = %{thread_id: state.thread_id, current_message_id: state.current_message_id}
          TWStream.emit_assistant_events(ctx, assistant_events)

          if tool_calls != [] do
            {:noreply, start_tool_task(state, tool_calls)}
          else
            state = complete_current_message(state, :completed, nil)
            broadcast(state, :turn_completed, %{thread_id: state.thread_id})
            state = finish_turn(state, {:ok, state.history_items})
            state = reply_interrupt_waiters(state, {:error, :turn_completed})
            {:noreply, start_next_turn(%{state | status: :idle})}
          end

        {:error, :interrupt} ->
          state = complete_current_message(state, :interrupted, :interrupted)
          broadcast(state, :turn_interrupted, %{thread_id: state.thread_id})
          state = finish_turn(state, {:error, :interrupted})
          state = reply_interrupt_waiters(state, :ok)
          {:noreply, start_next_turn(%{state | status: :idle})}

        {:error, :steer} ->
          state = complete_current_message(state, :interrupted, :steered)
          broadcast(state, :turn_interrupted, %{thread_id: state.thread_id})
          state = reply_interrupt_waiters(state, {:error, :steered})
          {:noreply, start_next_turn(state)}

        {:error, :pause} ->
          state = complete_current_message(state, :paused, :paused)
          broadcast(state, :turn_interrupted, %{thread_id: state.thread_id})
          state = finish_turn(state, {:error, :paused})
          state = reply_interrupt_waiters(state, {:error, :paused})
          {:noreply, %{state | status: :paused}}

        {:error, error} ->
          Logger.error("Codex API error: #{inspect(error)}")
          state = complete_current_message(state, :error, error)
          broadcast(state, :turn_error, %{thread_id: state.thread_id, error: error})
          state = finish_turn(state, {:error, error})
          state = reply_interrupt_waiters(state, {:error, error})
          {:noreply, start_next_turn(%{state | status: :idle})}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tool_results, ref, tool_results, state_updates}, state) do
    if ref == state.tool_task_ref do
      state = clear_tool_task(state)
      state = merge_tool_state(state, state_updates)
      state = TWHistory.append_history_items(state, tool_results)

      {:noreply, start_stream(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      ref == state.stream_monitor ->
        state = clear_stream(state)

        case reason do
          :normal ->
            {:noreply, state}

          :shutdown ->
            {:noreply, state}

          _ ->
            state = complete_current_message(state, :error, reason)
            broadcast(state, :turn_error, %{thread_id: state.thread_id, error: reason})
            state = finish_turn(state, {:error, reason})
            state = reply_interrupt_waiters(state, {:error, reason})
            {:noreply, start_next_turn(%{state | status: :idle})}
        end

      ref == state.tool_task_monitor ->
        state = clear_tool_task(state)

        case reason do
          :normal ->
            {:noreply, state}

          :shutdown ->
            {:noreply, state}

          _ ->
            state = complete_current_message(state, :error, reason)
            broadcast(state, :turn_error, %{thread_id: state.thread_id, error: reason})
            state = finish_turn(state, {:error, reason})
            state = reply_interrupt_waiters(state, {:error, reason})
            {:noreply, start_next_turn(%{state | status: :idle})}
        end

      true ->
        {agent_id, _child} =
          Enum.find(state.children, {nil, nil}, fn {_id, child} ->
            child.monitor_ref == ref or child.pid == pid
          end)

        state =
          if agent_id do
            children = Map.delete(state.children, agent_id)

            broadcast(state, :subagent_down, %{
              thread_id: state.thread_id,
              agent_id: agent_id,
              reason: reason
            })

            %{state | children: children}
            |> TWDispatch.drain_pending_spawns()
          else
            state
          end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Kill all children
    Enum.each(Map.keys(state.children), fn child_id ->
      TWDispatch.safe_kill(child_id)
    end)

    if is_binary(state.shell_session_id) do
      _ = EchsCore.Tools.Exec.kill_session(state.shell_session_id)
    end

    state = cancel_stream(state, reason, reply?: false)
    state = state |> release_turn_slot() |> clear_pending_slot()
    broadcast(state, :thread_terminated, %{thread_id: state.thread_id, reason: reason})
    :ok
  end

  # Private functions

  defp start_stream(%{status: :paused} = state), do: state

  defp start_stream(state) do
    cond do
      state.stream_pid != nil ->
        state

      state.pending_slot_ref != nil ->
        state

      state.current_slot_ref != nil ->
        do_start_stream(state)

      true ->
        case EchsCore.TurnLimiter.acquire() do
          {:ok, ref} ->
            do_start_stream(%{state | current_slot_ref: ref})

          {:wait, ref} ->
            %{state | pending_slot_ref: ref}
        end
    end
  end

  defp do_start_stream(state) do
    state = TWHistory.maybe_repair_missing_tool_outputs(state)
    stream_ref = make_ref()
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
        TWStream.run(state, stream_ref, parent)
      end)

    monitor_ref = Process.monitor(pid)

    %{
      state
      | stream_ref: stream_ref,
        stream_pid: pid,
        stream_monitor: monitor_ref,
        status: :running
    }
  end


  defp cancel_stream(state, reason, opts) do
    reply? = Keyword.get(opts, :reply?, true)

    state = complete_current_message(state, cancel_reason_status(reason), reason)

    if state.stream_pid do
      Process.exit(state.stream_pid, :shutdown)
    end

    if state.stream_monitor do
      Process.demonitor(state.stream_monitor, [:flush])
    end

    state = clear_stream(state)

    # Also kill any running tool execution task
    if state.tool_task_pid do
      Process.exit(state.tool_task_pid, :shutdown)
    end

    if state.tool_task_monitor do
      Process.demonitor(state.tool_task_monitor, [:flush])
    end

    state = clear_tool_task(state)

    state =
      if reply? do
        finish_turn(state, {:error, reason})
      else
        state
      end

    state = reply_interrupt_waiters(state, {:error, reason})

    broadcast(state, :turn_interrupted, %{thread_id: state.thread_id})
    state
  end

  defp clear_stream(state) do
    if state.stream_monitor do
      Process.demonitor(state.stream_monitor, [:flush])
    end

    %{state | stream_ref: nil, stream_pid: nil, stream_monitor: nil}
  end

  defp start_tool_task(state, tool_calls) do
    tool_ref = make_ref()
    parent = self()

    # Snapshot the mutable state fields that tool execution may modify
    state_snapshot = %{
      cwd: state.cwd,
      children: state.children,
      shell_session_id: state.shell_session_id,
      shell_session_cwd: state.shell_session_cwd,
      shell_session_login: state.shell_session_login,
      tool_handlers: state.tool_handlers,
      blackboard: state.blackboard,
      thread_id: state.thread_id,
      shell_path: state.shell_path,
      shell_snapshot_path: state.shell_snapshot_path,
      instructions: state.instructions,
      model: state.model,
      coordination_mode: state.coordination_mode,
      history_items: state.history_items,
      current_message_id: state.current_message_id,
      trace_id: state.trace_id,
      pending_agent_spawns: state.pending_agent_spawns,
      parent_thread_id: state.parent_thread_id,
      reasoning: state.reasoning
    }

    {:ok, pid} =
      Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
        {tool_results, final_state} = TWDispatch.execute_tool_calls(state_snapshot, tool_calls)

        state_updates = %{
          cwd: final_state.cwd,
          children: final_state.children,
          shell_session_id: final_state.shell_session_id,
          shell_session_cwd: final_state.shell_session_cwd,
          shell_session_login: final_state.shell_session_login
        }

        send(parent, {:tool_results, tool_ref, tool_results, state_updates})
      end)

    monitor_ref = Process.monitor(pid)

    %{state | tool_task_ref: tool_ref, tool_task_pid: pid, tool_task_monitor: monitor_ref}
  end

  defp clear_tool_task(state) do
    if state.tool_task_monitor do
      Process.demonitor(state.tool_task_monitor, [:flush])
    end

    %{state | tool_task_ref: nil, tool_task_pid: nil, tool_task_monitor: nil}
  end

  defp merge_tool_state(state, updates) when is_map(updates) do
    %{state |
      cwd: Map.get(updates, :cwd, state.cwd),
      children: Map.get(updates, :children, state.children),
      shell_session_id: Map.get(updates, :shell_session_id, state.shell_session_id),
      shell_session_cwd: Map.get(updates, :shell_session_cwd, state.shell_session_cwd),
      shell_session_login: Map.get(updates, :shell_session_login, state.shell_session_login)
    }
  end

  defp finish_turn(state, reply) do
    state =
      case state.reply_to do
        nil ->
          state

        from ->
          GenServer.reply(from, reply)
          %{state | reply_to: nil}
      end

    state
    |> Map.put(:current_message_id, nil)
    |> Map.put(:current_turn_started_at_ms, nil)
    |> Map.put(:trace_id, nil)
    |> touch()
  end

  defp release_turn_slot(%{current_slot_ref: nil} = state), do: state

  defp release_turn_slot(state) do
    EchsCore.TurnLimiter.release(state.current_slot_ref)
    %{state | current_slot_ref: nil}
  end

  defp clear_pending_slot(%{pending_slot_ref: nil} = state), do: state

  defp clear_pending_slot(state) do
    EchsCore.TurnLimiter.cancel(state.pending_slot_ref)
    %{state | pending_slot_ref: nil}
  end

  defp request_stream_control(state, control) do
    if state.stream_pid do
      send(state.stream_pid, {:stream_control, control})
    end

    state
  end

  defp reply_interrupt_waiters(state, reply) do
    Enum.each(state.pending_interrupts, fn from ->
      GenServer.reply(from, reply)
    end)

    %{state | pending_interrupts: []}
  end

  defp send_mode(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode)

    cond do
      mode in [:steer, "steer"] -> :steer
      Keyword.get(opts, :steer, false) -> :steer
      mode in [:queue, "queue"] -> :queue
      true -> :queue
    end
  end

  defp send_mode(_opts), do: :queue


  defp add_user_message(state, content) when is_binary(content) do
    content_items = [%{"type" => "input_text", "text" => content}]
    content_items = TWConfig.maybe_inject_claude_instructions(state, content_items)

    user_item = %{
      "type" => "message",
      "role" => "user",
      "content" => content_items
    }

    state
    |> TWHistory.append_history_items([user_item])
    |> Map.put(:status, :running)
  end

  defp add_user_message(state, content) when is_list(content) do
    content_items =
      content
      |> Enum.map(&normalize_message_content_item/1)
      |> Enum.reject(&is_nil/1)

    content_items = TWConfig.maybe_inject_claude_instructions(state, content_items)

    user_item = %{
      "type" => "message",
      "role" => "user",
      "content" => content_items
    }

    state
    |> TWHistory.append_history_items([user_item])
    |> Map.put(:status, :running)
  end

  defp add_user_message(state, _content) do
    add_user_message(state, "")
  end

  defp normalize_message_content_item(item) when is_map(item) do
    normalized =
      Enum.reduce(item, %{}, fn {k, v}, acc ->
        Map.put(acc, to_string(k), v)
      end)

    case normalized do
      %{"type" => type} when is_binary(type) and type != "" ->
        normalized

      _ ->
        nil
    end
  end

  defp normalize_message_content_item(_item), do: nil

  defp enqueue_turn(state, from, content, opts, message_id) do
    turn = %{
      from: from,
      content: content,
      opts: opts,
      message_id: message_id,
      enqueued_at_ms: now_ms()
    }

    %{touch(state) | queued_turns: state.queued_turns ++ [turn]}
  end

  defp enqueue_steer(state, from, content, opts, message_id, preserve_reply?: preserve_reply?) do
    turn = %{
      from: from,
      content: content,
      opts: opts,
      message_id: message_id,
      enqueued_at_ms: now_ms(),
      preserve_reply?: preserve_reply?
    }

    %{touch(state) | steer_queue: state.steer_queue ++ [turn]}
  end

  defp start_next_turn(state) do
    cond do
      state.status == :paused ->
        state

      state.stream_pid != nil ->
        state

      state.tool_task_pid != nil ->
        state

      state.resume_turns != [] ->
        start_resume_turn(state)

      state.steer_queue != [] ->
        start_steer_turn(state)

      state.queued_turns != [] ->
        start_queued_turn(state)

      true ->
        %{state | status: :idle}
    end
  end

  defp start_queued_turn(state) do
    [next | rest] = state.queued_turns
    state = %{state | queued_turns: rest, reply_to: next.from}

    state =
      state
      |> begin_turn(next.message_id)
      |> TWConfig.apply_turn_config(next.opts)
      |> add_user_message(next.content)

    broadcast(state, :turn_started, %{thread_id: state.thread_id})
    start_stream(state)
  end

  defp start_resume_turn(state) do
    [next | rest] = state.resume_turns
    state = %{state | resume_turns: rest, reply_to: next.from}

    state =
      state
      |> resume_turn(next.message_id)
      |> TWConfig.apply_turn_config(next.opts)

    broadcast(state, :turn_started, %{thread_id: state.thread_id})
    start_stream(state)
  end

  defp start_steer_turn(state) do
    [next | rest] = state.steer_queue
    state = %{state | steer_queue: rest}

    state =
      if next.preserve_reply? do
        state
      else
        state
        |> finish_turn({:error, :interrupted})
        |> Map.put(:reply_to, next.from)
      end

    state =
      state
      |> begin_turn(next.message_id)
      |> TWConfig.apply_turn_config(next.opts)
      |> add_user_message(next.content)

    broadcast(state, :turn_started, %{thread_id: state.thread_id})
    start_stream(state)
  end


  defp broadcast(state, event_type, data) do
    data =
      data
      |> maybe_put(:message_id, state.current_message_id)
      |> maybe_put(:trace_id, state.trace_id)

    Phoenix.PubSub.broadcast(
      EchsCore.PubSub,
      "thread:#{state.thread_id}",
      {event_type, data}
    )
  end

  defp maybe_put(data, _key, nil), do: data
  defp maybe_put(data, key, value), do: Map.put_new(data, key, value)

  defp generate_id do
    "thr_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_message_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp message_id_for_turn(_state, opts) when is_list(opts) do
    case Keyword.get(opts, :message_id) do
      id when is_binary(id) and id != "" -> id
      _ -> generate_message_id()
    end
  end

  defp message_id_for_turn(state, _opts) do
    message_id_for_turn(state, [])
  end

  @max_message_ids 1_000

  defp begin_turn(state, message_id) when is_binary(message_id) and message_id != "" do
    now = now_ms()
    history_start = length(state.history_items)
    trace_id = generate_trace_id()

    EchsCore.Telemetry.turn_start(state.thread_id, message_id, state.model)

    state =
      state
      |> remember_message_id(message_id)
      |> message_log_start(message_id, now, history_start)
      |> Map.put(:current_message_id, message_id)
      |> Map.put(:current_turn_started_at_ms, now)
      |> Map.put(:trace_id, trace_id)
      |> touch()

    _ = TWPersist.persist_message(state, message_id)
    state
  end

  defp resume_turn(state, message_id) when is_binary(message_id) and message_id != "" do
    now = now_ms()

    meta =
      state.message_log
      |> Map.get(message_id, %{message_id: message_id})

    history_start = meta.history_start || length(state.history_items)

    meta =
      meta
      |> Map.put_new(:enqueued_at_ms, now)
      |> Map.put_new(:started_at_ms, now)
      |> Map.put(:status, :running)
      |> Map.put(:history_start, history_start)
      |> Map.put(:history_end, nil)
      |> Map.put(:error, nil)

    state =
      state
      |> remember_message_id(message_id)
      |> touch()
      |> Map.put(:current_message_id, message_id)
      |> Map.put(:current_turn_started_at_ms, now)
      |> Map.put(:trace_id, generate_trace_id())

    state =
      %{state | message_log: Map.put(state.message_log, message_id, normalize_message_meta(meta))}

    _ = TWPersist.persist_message(state, message_id)
    state
  end

  defp message_log_enqueue(state, message_id, request_json)
       when is_binary(message_id) and message_id != "" do
    now = now_ms()

    meta =
      state.message_log
      |> Map.get(message_id, %{message_id: message_id})
      |> Map.put_new(:enqueued_at_ms, now)
      |> Map.put(:status, :queued)
      |> maybe_put_new(:request_json, request_json)

    %{state | message_log: Map.put(state.message_log, message_id, normalize_message_meta(meta))}
    |> touch()
  end

  defp message_log_enqueue(state, _message_id, _request_json), do: state

  defp message_log_start(state, message_id, started_at_ms, history_start)
       when is_binary(message_id) and message_id != "" do
    meta =
      state.message_log
      |> Map.get(message_id, %{message_id: message_id})
      |> Map.put_new(:enqueued_at_ms, started_at_ms)
      |> Map.put(:status, :running)
      |> Map.put(:started_at_ms, started_at_ms)
      |> Map.put(:completed_at_ms, nil)
      |> Map.put(:history_start, history_start)
      |> Map.put(:history_end, nil)
      |> Map.put(:error, nil)

    %{state | message_log: Map.put(state.message_log, message_id, normalize_message_meta(meta))}
  end

  defp complete_current_message(%{current_message_id: nil} = state, _status, _error), do: state

  defp complete_current_message(state, status, error) do
    message_id = state.current_message_id
    now = now_ms()

    duration_ms =
      if state.current_turn_started_at_ms,
        do: now - state.current_turn_started_at_ms,
        else: 0

    if error do
      EchsCore.Telemetry.turn_exception(state.thread_id, message_id, state.model, error, duration_ms)
    else
      EchsCore.Telemetry.turn_stop(state.thread_id, message_id, state.model, status, duration_ms)
    end

    meta =
      state.message_log
      |> Map.get(message_id, %{message_id: message_id})
      |> Map.put_new(:enqueued_at_ms, now)
      |> Map.put_new(:started_at_ms, state.current_turn_started_at_ms || now)
      |> Map.put(:status, status)
      |> Map.put(:completed_at_ms, now)
      |> Map.put(:history_end, length(state.history_items))
      |> Map.put(:error, error)

    state =
      %{state | message_log: Map.put(state.message_log, message_id, normalize_message_meta(meta))}
      |> release_turn_slot()
      |> clear_pending_slot()
      |> touch()

    _ = TWPersist.persist_message(state, message_id)
    state
  end

  defp cancel_reason_status(:paused), do: :paused
  defp cancel_reason_status(_), do: :interrupted

  defp remember_message_id(state, message_id) when is_binary(message_id) and message_id != "" do
    if MapSet.member?(state.message_id_set, message_id) do
      state
    else
      message_ids = state.message_ids ++ [message_id]
      message_id_set = MapSet.put(state.message_id_set, message_id)

      {message_ids, message_id_set, dropped} = trim_message_id_cache(message_ids, message_id_set)

      message_log =
        Enum.reduce(dropped, state.message_log, fn id, acc ->
          Map.delete(acc, id)
        end)

      %{
        state
        | message_ids: message_ids,
          message_id_set: message_id_set,
          message_log: message_log
      }
    end
  end

  defp remember_message_id(state, _message_id), do: state

  defp trim_message_id_cache(message_ids, message_id_set) do
    extra = length(message_ids) - @max_message_ids

    if extra > 0 do
      {dropped, kept} = Enum.split(message_ids, extra)

      message_id_set =
        Enum.reduce(dropped, message_id_set, fn id, acc -> MapSet.delete(acc, id) end)

      {kept, message_id_set, dropped}
    else
      {message_ids, message_id_set, []}
    end
  end

  defp touch(state) do
    # Use Map.put to handle old states that may lack this field
    Map.put(state, :last_activity_at_ms, now_ms())
  end

  defp clamp_int(value, min, max) when is_integer(value) do
    value |> min(max) |> max(min)
  end

  defp clamp_int(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> clamp_int(int, min, max)
      :error -> min
    end
  end

  defp clamp_int(_value, min, _max), do: min

  defp normalize_message_meta(meta) when is_map(meta) do
    meta
    |> Map.put_new(:enqueued_at_ms, nil)
    |> Map.put_new(:started_at_ms, nil)
    |> Map.put_new(:completed_at_ms, nil)
    |> Map.put_new(:history_start, nil)
    |> Map.put_new(:history_end, nil)
    |> Map.put_new(:error, nil)
    |> Map.put_new(:request_json, nil)
  end

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  defp encode_message_request(content, opts, mode) do
    configure =
      case Keyword.get(opts, :configure) do
        cfg when is_map(cfg) -> cfg
        _ -> %{}
      end

    payload = %{
      "mode" => to_string(mode),
      "configure" => configure,
      "content" => content
    }

    try do
      Jason.encode!(payload)
    rescue
      Jason.EncodeError ->
        Jason.encode!(%{
          "mode" => to_string(mode),
          "configure" => %{},
          "content" => inspect(content, limit: 2000, printable_limit: 2000)
        })
    end
  end

  defp now_ms do
    System.system_time(:millisecond)
  end

  defp generate_trace_id do
    "trc_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
