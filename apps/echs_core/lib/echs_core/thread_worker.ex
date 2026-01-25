defmodule EchsCore.ThreadWorker do
  @moduledoc """
  GenServer managing a single conversation thread.
  Handles the full tool loop, sub-agents, and state.
  """

  use GenServer
  require Logger

  alias EchsCore.{Tools, Blackboard}

  @default_system_prompt """
  You are an autonomous coding agent with full system access. No approvals, no restrictions, no hand-holding.

  ## Capabilities

  - **Shell**: Run any command via `exec_command` (session-based, port-backed stdio) or `local_shell`
  - **Files**: Read, write, patch, grep - full filesystem access
  - **Sub-agents**: Spawn parallel workers, coordinate via blackboard, divide and conquer
  - **Research**: Web searches, file exploration, code analysis - do what you need to understand the problem

  ## Philosophy

  **Autonomy over permission.** Don't ask if you should do something - just do it. Don't explain what you're about to do - do it and show results. The user trusts you with full access because they want results, not conversation.

  **Depth over breadth.** When researching or debugging, go deep. Read the actual code. Trace the actual execution. Don't guess - verify. If you're unsure, investigate until you're certain.

  **Parallelism over sequence.** When tasks can be parallelized, spawn sub-agents. A 3-agent swarm finishing in 10 seconds beats a single agent taking 30. Use `spawn_agent` aggressively.

  **Persistence over surrender.** When something fails, try another approach. Check error messages, read logs, inspect state. The answer exists - find it. Only yield back to the user when genuinely stuck or when the task is complete.

  ## Working Style

  - **Research tasks**: Explore thoroughly. Read multiple files. Search codebases. Check git history. Build a mental model before acting.
  - **Implementation tasks**: Plan briefly, then execute. Use apply_patch for surgical edits. Verify your changes work.
  - **Debugging tasks**: Reproduce first. Understand the system. Fix the root cause, not the symptom.
  - **Multi-step tasks**: Break into sub-tasks. Assign to sub-agents when parallel. Use blackboard for coordination.

  ## Sub-Agent Coordination

  You can spawn sub-agents with `spawn_agent`. Each gets their own context and tools.

  **Hierarchical** (default): You control them, they report to you.
  **Blackboard**: Shared state via `blackboard_write`/`blackboard_read`. Great for parallel work on shared data.
  **Peer**: Equal agents working together (use sparingly).

  Sub-agent tips:
  - Give clear, self-contained tasks
  - Use `wait_agents` to collect results
  - Sub-agents can write to blackboard with `notify_parent: true` to interrupt you with updates
  - Kill agents when done with `kill_agent`

  ## Output Format

  Be concise. Lead with results, not process. Use:
  - Backticks for `code`, `paths`, `commands`
  - Brief headers only when they help scanability
  - Bullets for lists, but don't over-structure
  - Show relevant output snippets, not full dumps

  Skip preamble. Skip "I'll now..." - just do it. The user sees your tool calls.

  ## Current Environment

  Workspace: {{cwd}}
  Sandboxing: None (full access)
  Approvals: Never required
  Network: Unrestricted
  """

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
    :steer_queue,
    :tool_handlers
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
          steer_queue: [steer_turn()],
          tool_handlers: %{optional(String.t()) => tool_handler()}
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

    # Subscribe to blackboard events for cross-thread coordination.
    #
    # We filter events in `handle_info/2` so only relevant threads react (e.g. a
    # parent thread should only handle notifications coming from its children).
    :ok = Phoenix.PubSub.subscribe(EchsCore.PubSub, "blackboard")

    state = %__MODULE__{
      thread_id: thread_id,
      parent_thread_id: parent_thread_id,
      created_at_ms: created_at_ms,
      last_activity_at_ms: last_activity_at_ms,
      model: Keyword.get(opts, :model, "gpt-5.2-codex"),
      reasoning: Keyword.get(opts, :reasoning, "medium"),
      cwd: cwd,
      instructions: build_instructions(Keyword.get(opts, :instructions), cwd),
      tools: Keyword.get(opts, :tools, default_tools()),
      history_items: history_items,
      status: :idle,
      current_message_id: nil,
      current_turn_started_at_ms: nil,
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
      steer_queue: steer_queue,
      tool_handlers: %{}
    }

    broadcast(state, :thread_created, %{thread_id: thread_id, config: config_summary(state)})

    _ = persist_thread(state)

    if state.queued_turns != [] or state.steer_queue != [] do
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

      _ = persist_message(state, message_id)

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
        |> apply_turn_config(opts)
        |> add_user_message(content)

      _ = persist_message(state, message_id)

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

    _ = persist_message(state, message_id)

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
      |> apply_turn_config(opts)
      |> add_user_message(content)

    _ = persist_message(state, message_id)

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
      |> apply_config(config)
      |> touch()

    _ = persist_thread(state)

    broadcast(state, :thread_configured, %{thread_id: state.thread_id, changes: config})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_tool, spec, handler}, _from, state) do
    case normalize_tool_spec(spec) do
      {:ok, normalized, name} ->
        state = %{
          state
          | tools: uniq_tools(state.tools ++ [normalized]),
            tool_handlers: Map.put(state.tool_handlers, name, handler)
        }

        _ = persist_thread(state)

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
      | tools: remove_tool_spec(state.tools, name),
        tool_handlers: Map.delete(state.tool_handlers, name)
    }

    _ = persist_thread(state)

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
    {:reply, :ok, touch(%{state | status: :idle})}
  end

  @impl true
  def handle_call(:interrupt, from, state) do
    if state.stream_pid do
      state = request_stream_control(state, :interrupt)
      state = %{state | pending_interrupts: [from | state.pending_interrupts]}
      {:noreply, state}
    else
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
  def handle_info({:stream_complete, ref, result, collected_items}, state) do
    if ref == state.stream_ref do
      state = clear_stream(state)

      case result do
        {:ok, _} ->
          state = append_history_items(state, collected_items)

          tool_calls =
            Enum.filter(collected_items, fn item ->
              item["type"] in ["function_call", "local_shell_call"]
            end)

          if tool_calls != [] do
            {tool_results, state} = execute_tool_calls(state, tool_calls)
            state = append_history_items(state, tool_results)
            {:noreply, start_stream(state)}
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
      safe_kill(child_id)
    end)

    _ = cancel_stream(state, reason, reply?: false)
    broadcast(state, :thread_terminated, %{thread_id: state.thread_id, reason: reason})
    :ok
  end

  # Private functions

  defp start_stream(%{status: :paused} = state), do: state

  defp start_stream(state) do
    if state.stream_pid do
      state
    else
      stream_ref = make_ref()
      parent = self()

      {:ok, pid} =
        Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
          run_stream_request(state, stream_ref, parent)
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
  end

  defp run_stream_request(state, stream_ref, parent) do
    {:ok, items_agent} = Agent.start_link(fn -> [] end)
    Process.put(:pending_control, nil)

    {result, collected_items} =
      try do
        on_event = fn event ->
          handle_sse_event(state, event, items_agent)
          poll_stream_control()
          maybe_abort_after_event(event)
        end

        api_input =
          Enum.filter(state.history_items, fn item ->
            item["type"] in [
              "message",
              "function_call",
              "local_shell_call",
              "function_call_output"
            ]
          end)
          |> expand_uploads_for_api()

        result =
          EchsCodex.stream_response(
            model: state.model,
            instructions: state.instructions,
            input: api_input,
            tools: state.tools,
            reasoning: state.reasoning,
            on_event: on_event
          )

        {result, Agent.get(items_agent, & &1)}
      catch
        {:stream_control, control} ->
          {{:error, control}, Agent.get(items_agent, & &1)}
      after
        Agent.stop(items_agent)
      end

    send(parent, {:stream_complete, stream_ref, result, collected_items})
  end

  defp poll_stream_control do
    receive do
      {:stream_control, control} ->
        update_pending_control(control)
        poll_stream_control()
    after
      0 -> :ok
    end
  end

  defp update_pending_control(control) do
    current = Process.get(:pending_control)

    next =
      case {current, control} do
        {nil, new} -> new
        {:interrupt, _} -> :interrupt
        {:pause, :interrupt} -> :interrupt
        {:pause, _} -> :pause
        {:steer, :interrupt} -> :interrupt
        {:steer, :pause} -> :pause
        {:steer, _} -> :steer
        _ -> control
      end

    Process.put(:pending_control, next)
  end

  defp maybe_abort_after_event(event) do
    case Process.get(:pending_control) do
      nil ->
        :ok

      control ->
        if stream_control_boundary?(event) do
          throw({:stream_control, control})
        end
    end
  end

  defp stream_control_boundary?(%{"type" => "response.output_item.done"}), do: true
  defp stream_control_boundary?(%{"type" => "response.completed"}), do: true
  defp stream_control_boundary?(%{"type" => "done"}), do: true
  defp stream_control_boundary?(_), do: false

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

    if reply? do
      _ = finish_turn(state, {:error, reason})
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
    |> touch()
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

  defp apply_turn_config(state, opts) when is_list(opts) do
    apply_config(state, Keyword.get(opts, :configure, %{}))
  end

  defp apply_turn_config(state, _opts), do: state

  defp add_user_message(state, content) when is_binary(content) do
    user_item = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => content}]
    }

    state
    |> append_history_items([user_item])
    |> Map.put(:status, :running)
  end

  defp add_user_message(state, content) when is_list(content) do
    content_items =
      content
      |> Enum.map(&normalize_message_content_item/1)
      |> Enum.reject(&is_nil/1)

    user_item = %{
      "type" => "message",
      "role" => "user",
      "content" => content_items
    }

    state
    |> append_history_items([user_item])
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
      |> apply_turn_config(next.opts)
      |> add_user_message(next.content)

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
      |> apply_turn_config(next.opts)
      |> add_user_message(next.content)

    broadcast(state, :turn_started, %{thread_id: state.thread_id})
    start_stream(state)
  end

  defp execute_tool_calls(state, tool_calls) do
    Enum.map_reduce(tool_calls, state, fn call, acc_state ->
      {result, next_state} = execute_tool_call(acc_state, call)
      call_id = call["call_id"] || call["id"]

      broadcast(acc_state, :tool_completed, %{
        thread_id: acc_state.thread_id,
        call_id: call_id,
        result: result
      })

      tool_result = %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => format_tool_result(result)
      }

      {tool_result, next_state}
    end)
  end

  defp format_tool_result(result) when is_binary(result), do: sanitize_binary(result)
  defp format_tool_result({:ok, data}) when is_binary(data), do: sanitize_binary(data)

  defp format_tool_result({:ok, data}) do
    try do
      Jason.encode!(data)
    rescue
      Jason.EncodeError ->
        # Data contains invalid bytes (e.g., binary file content)
        inspect(data, limit: 5000, printable_limit: 5000)
    end
  end

  defp format_tool_result({:error, err}), do: "Error: #{inspect(err)}"
  defp format_tool_result(:ok), do: "OK"
  defp format_tool_result(other), do: inspect(other)

  # Sanitize binary data to ensure valid UTF-8 for JSON encoding
  defp sanitize_binary(data) do
    if String.valid?(data) do
      data
    else
      # Replace invalid bytes with replacement character
      data
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _rest} -> valid <> " [binary data truncated]"
        {:incomplete, valid, _rest} -> valid <> " [binary data truncated]"
        valid when is_binary(valid) -> valid
      end
    end
  end

  defp handle_sse_event(state, event, items_agent) do
    case event["type"] do
      "response.output_item.added" ->
        broadcast(state, :item_started, %{thread_id: state.thread_id, item: event["item"]})

      "response.output_text.delta" ->
        broadcast(state, :turn_delta, %{thread_id: state.thread_id, content: event["delta"]})

      "response.output_item.done" ->
        item = event["item"]
        broadcast(state, :item_completed, %{thread_id: state.thread_id, item: item})
        # Collect the item
        Agent.update(items_agent, fn items -> items ++ [item] end)

      "response.completed" ->
        :ok

      "done" ->
        :ok

      _ ->
        :ok
    end
  end

  defp execute_tool_call(state, item) do
    case item["type"] do
      "local_shell_call" ->
        # Execute shell command - the API sends ["bash", "-lc", "actual_command"]
        command = get_in(item, ["action", "command"]) || []
        cwd = get_in(item, ["action", "working_directory"]) || state.cwd
        timeout_ms = get_in(item, ["action", "timeout_ms"]) || 120_000

        # The command is already formatted as [executable, ...args]
        # Usually ["bash", "-lc", "the actual command"]
        case command do
          [cmd | args] ->
            {execute_shell_direct(cmd, args, cwd, timeout_ms), state}

          [] ->
            {"Error: empty command", state}
        end

      "function_call" ->
        name = item["name"]

        case decode_tool_args(item["arguments"]) do
          {:ok, args} ->
            execute_named_tool(state, name, args)

          {:error, reason} ->
            {{:error, reason}, state}
        end

      _ ->
        {{:error, "Unknown item type: #{item["type"]}"}, state}
    end
  end

  defp decode_tool_args(nil), do: {:ok, %{}}
  defp decode_tool_args(args) when is_map(args), do: {:ok, args}

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, "Invalid tool arguments: #{Exception.message(error)}"}
    end
  end

  defp decode_tool_args(_), do: {:ok, %{}}

  defp execute_named_tool(state, name, args) do
    case name do
      "shell" ->
        cwd = args["workdir"] || state.cwd
        timeout_ms = args["timeout_ms"] || 120_000
        {Tools.Shell.execute(args["command"], cwd: cwd, timeout_ms: timeout_ms), state}

      "exec_command" ->
        {exec_command(state, args), state}

      "write_stdin" ->
        {write_stdin(state, args), state}

      "read_file" ->
        {Tools.Files.read_file(args["file_path"], args), state}

      "list_dir" ->
        {Tools.Files.list_dir(args["dir_path"], args), state}

      "grep_files" ->
        {Tools.Files.grep_files(args["pattern"], args["paths"], args), state}

      "apply_patch" ->
        {Tools.ApplyPatch.apply(args["patch"], cwd: state.cwd), state}

      "view_image" ->
        attach_image(state, args)

      "spawn_agent" ->
        spawn_subagent(state, args)

      "send_to_agent" ->
        {send_to_subagent(state, args), state}

      "wait_agents" ->
        {wait_for_agents(state, args), state}

      "blackboard_write" ->
        {blackboard_write(state, args), state}

      "blackboard_read" ->
        {blackboard_read(state, args), state}

      "kill_agent" ->
        kill_subagent(state, args)

      _ ->
        execute_custom_tool(state, name, args)
    end
  end

  defp attach_image(state, args) do
    path = args["path"] || args["file_path"] || ""

    case Tools.ViewImage.build_message_item(path, cwd: state.cwd) do
      {:ok, message_item} ->
        {"attached local image", append_history_items(state, [message_item])}

      {:error, {:too_large, size, max_bytes}} ->
        msg = "image too large (#{size} bytes > #{max_bytes} bytes): #{path}"
        {{:error, msg}, state}

      {:error, {:not_a_file, type}} ->
        msg = "image path is not a file (#{inspect(type)}): #{path}"
        {{:error, msg}, state}

      {:error, reason} ->
        msg = "unable to attach image #{path}: #{inspect(reason)}"
        {{:error, msg}, state}
    end
  end

  defp spawn_subagent(state, args) do
    agent_id = generate_id()

    # Validate reasoning level - only these are valid for Codex
    reasoning =
      case args["reasoning"] do
        level when level in ["low", "medium", "high", "xhigh"] -> level
        "minimal" -> "low"
        "none" -> "low"
        _ -> state.reasoning
      end

    opts = [
      thread_id: agent_id,
      parent_thread_id: state.thread_id,
      cwd: state.cwd,
      model: state.model,
      reasoning: reasoning,
      tools: filter_tools(args["tools"]),
      coordination_mode: parse_coordination(args["coordination"])
    ]

    case create(opts) do
      {:ok, ^agent_id} ->
        # Run the agent asynchronously; use `wait_agents` to join later.
        _ =
          Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
            _ = send_message(agent_id, args["task"])
            :ok
          end)

        broadcast(state, :subagent_spawned, %{
          thread_id: state.thread_id,
          agent_id: agent_id,
          task: args["task"]
        })

        child_pid = lookup_thread_pid(agent_id)
        monitor_ref = if is_pid(child_pid), do: Process.monitor(child_pid), else: nil
        children = Map.put(state.children, agent_id, %{pid: child_pid, monitor_ref: monitor_ref})

        {{:ok, %{agent_id: agent_id}}, %{state | children: children}}

      error ->
        {error, state}
    end
  end

  defp send_to_subagent(_state, args) do
    agent_id = args["agent_id"]
    message = args["message"]

    if args["interrupt"] do
      safe_interrupt(agent_id)
    end

    _ =
      Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
        _ = safe_send_message(agent_id, message)
        :ok
      end)

    {:ok, %{agent_id: agent_id, status: "sent"}}
  end

  defp execute_custom_tool(state, name, args) do
    case Map.fetch(state.tool_handlers, name) do
      {:ok, handler} ->
        ctx = %{thread_id: state.thread_id, cwd: state.cwd, blackboard: state.blackboard}

        result =
          try do
            invoke_tool_handler(handler, args, ctx)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, reason}
          end

        {result, state}

      :error ->
        {{:error, "Unknown tool: #{name}"}, state}
    end
  end

  defp invoke_tool_handler(handler, args, ctx) when is_function(handler, 2) do
    handler.(args, ctx)
  end

  defp invoke_tool_handler(handler, args, _ctx) when is_function(handler, 1) do
    handler.(args)
  end

  defp invoke_tool_handler({mod, fun}, args, ctx) do
    call_mfa(mod, fun, args, ctx, [])
  end

  defp invoke_tool_handler({mod, fun, extra}, args, ctx) when is_list(extra) do
    call_mfa(mod, fun, args, ctx, extra)
  end

  defp invoke_tool_handler(_handler, _args, _ctx) do
    {:error, :invalid_handler}
  end

  defp call_mfa(mod, fun, args, ctx, extra) do
    cond do
      function_exported?(mod, fun, 2 + length(extra)) ->
        apply(mod, fun, [args, ctx | extra])

      function_exported?(mod, fun, 1 + length(extra)) ->
        apply(mod, fun, [args | extra])

      function_exported?(mod, fun, length(extra)) ->
        apply(mod, fun, extra)

      true ->
        {:error, :handler_not_exported}
    end
  end

  defp wait_for_agents(_state, args) do
    agent_ids = args["agent_ids"]
    mode = args["mode"] || "all"
    timeout = args["timeout_ms"] || 600_000

    start_time = System.monotonic_time(:millisecond)
    results = %{}

    wait_loop(agent_ids, mode, timeout, start_time, results)
  end

  defp wait_loop([], _mode, _timeout, _start_time, results) do
    {:ok, %{results: results, timed_out: false}}
  end

  defp wait_loop(agent_ids, mode, timeout, start_time, results) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= timeout do
      {:ok, %{results: results, timed_out: true}}
    else
      states =
        Enum.into(agent_ids, %{}, fn id ->
          {id, safe_get_state(id)}
        end)

      {completed, still_running} =
        Enum.split_with(agent_ids, fn id ->
          case Map.get(states, id) do
            %{status: :idle} -> true
            nil -> true
            _ -> false
          end
        end)

      new_results =
        Enum.reduce(completed, results, fn id, acc ->
          case Map.get(states, id) do
            %{history_items: history} ->
              Map.put(acc, id, %{status: :completed, history: history})

            nil ->
              Map.put(acc, id, %{status: :not_found})

            _ ->
              Map.put(acc, id, %{status: :unknown})
          end
        end)

      case mode do
        "any" when completed != [] ->
          {:ok, %{results: new_results, timed_out: false, remaining: still_running}}

        "all" when still_running == [] ->
          {:ok, %{results: new_results, timed_out: false}}

        _ ->
          Process.sleep(100)
          wait_loop(still_running, mode, timeout, start_time, new_results)
      end
    end
  end

  defp blackboard_write(state, args) do
    opts = [
      notify_parent: args["notify_parent"] || false,
      steer_message: args["steer_message"],
      by: state.thread_id
    ]

    # Use global blackboard for cross-agent coordination
    Blackboard.set(EchsCore.Blackboard.Global, args["key"], args["value"], opts)
    "OK: wrote '#{args["key"]}'"
  end

  defp blackboard_read(_state, args) do
    # Use global blackboard for cross-agent coordination
    case Blackboard.get(EchsCore.Blackboard.Global, args["key"]) do
      {:ok, value} -> "Value: #{inspect(value)}"
      :not_found -> "Key '#{args["key"]}' not found"
    end
  end

  defp kill_subagent(state, args) do
    agent_id = args["agent_id"]
    safe_kill(agent_id)
    {child, children} = Map.pop(state.children, agent_id)

    if child && child.monitor_ref do
      Process.demonitor(child.monitor_ref, [:flush])
    end

    {:ok, %{state | children: children}}
  end

  defp exec_command(state, args) do
    cmd = args["cmd"]
    cwd = args["workdir"] || state.cwd
    shell = args["shell"] || "/bin/bash"
    login = Map.get(args, "login", true)
    yield_time_ms = args["yield_time_ms"] || 10_000
    max_tokens = args["max_output_tokens"] || 10_000

    Tools.Exec.exec_command(
      cmd: cmd,
      cwd: cwd,
      shell: shell,
      login: login,
      yield_time_ms: yield_time_ms,
      max_output_tokens: max_tokens
    )
  end

  defp write_stdin(_state, args) do
    session_id = args["session_id"]
    chars = args["chars"] || ""
    yield_time_ms = args["yield_time_ms"] || 250
    max_tokens = args["max_output_tokens"] || 10_000

    Tools.Exec.write_stdin(
      session_id: session_id,
      chars: chars,
      yield_time_ms: yield_time_ms,
      max_output_tokens: max_tokens
    )
  end

  defp execute_shell_direct(cmd, args, cwd, timeout_ms) do
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        {output, exit_code} =
          System.cmd(cmd, args,
            cd: cwd,
            stderr_to_stdout: true,
            env: [{"TERM", "dumb"}],
            timeout: timeout_ms
          )

        {:ok, output, exit_code}
      rescue
        e ->
          {:error, Exception.message(e)}
      catch
        :exit, {:timeout, _} ->
          {:error, :timeout}
      end

    duration = (System.monotonic_time(:millisecond) - start_time) / 1000

    case result do
      {:ok, output, exit_code} ->
        # Truncate if too long
        max_length = 100_000

        truncated =
          if String.length(output) > max_length do
            String.slice(output, 0, max_length) <> "\n... [truncated]"
          else
            output
          end

        """
        Exit code: #{exit_code}
        Wall time: #{Float.round(duration, 3)} seconds
        Output:
        #{truncated}
        """

      {:error, :timeout} ->
        "Exit code: -1\nWall time: #{duration} seconds\nOutput:\nCommand timed out after #{timeout_ms}ms"

      {:error, message} ->
        "Exit code: -1\nWall time: #{duration} seconds\nOutput:\nError: #{message}"
    end
  end

  defp parse_coordination(nil), do: :hierarchical
  defp parse_coordination("hierarchical"), do: :hierarchical
  defp parse_coordination("blackboard"), do: :blackboard
  defp parse_coordination("peer"), do: :peer
  defp parse_coordination(_), do: :hierarchical

  defp lookup_thread_pid(thread_id) do
    case Registry.lookup(EchsCore.Registry, thread_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp safe_get_state(thread_id) do
    try do
      get_state(thread_id)
    catch
      :exit, _ -> nil
    end
  end

  defp safe_send_message(thread_id, message) do
    try do
      send_message(thread_id, message)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp safe_interrupt(thread_id) do
    try do
      interrupt(thread_id)
    catch
      :exit, _ -> :ok
    end
  end

  defp safe_kill(thread_id) do
    try do
      kill(thread_id)
    catch
      :exit, _ -> :ok
    end
  end

  defp apply_config(state, config) when is_map(config) do
    new_cwd = Map.get(config, "cwd", state.cwd)

    state
    |> maybe_update(:model, config["model"])
    |> maybe_update(:reasoning, config["reasoning"])
    |> maybe_update(:cwd, new_cwd)
    |> maybe_update(:instructions, config["instructions"], fn v ->
      build_instructions(v, new_cwd)
    end)
    |> maybe_update_tools(config["tools"])
  end

  defp maybe_update(state, _key, nil), do: state
  defp maybe_update(state, key, value), do: Map.put(state, key, value)
  defp maybe_update(state, _key, nil, _transform), do: state
  defp maybe_update(state, key, value, transform), do: Map.put(state, key, transform.(value))

  defp maybe_update_tools(state, nil), do: state

  defp maybe_update_tools(state, tools) do
    # Tools can be ["+tool", "-tool"] to add/remove
    {new_tools, removed} =
      Enum.reduce(tools, {state.tools, MapSet.new()}, fn
        "+" <> tool_name, {acc, removed} ->
          {add_tool(acc, tool_name), removed}

        "-" <> tool_name, {acc, removed} ->
          {remove_tool_spec(acc, tool_name), MapSet.put(removed, tool_name)}

        tool_def, {acc, removed} when is_map(tool_def) ->
          case normalize_tool_spec(tool_def) do
            {:ok, normalized, _name} -> {acc ++ [normalized], removed}
            {:error, _} -> {acc, removed}
          end

        _tool, {acc, removed} ->
          {acc, removed}
      end)

    new_tools = uniq_tools(new_tools)

    removed_names =
      Enum.reduce(removed, MapSet.new(), fn name, acc ->
        MapSet.put(acc, to_string(name))
      end)

    new_handlers =
      Enum.reduce(removed_names, state.tool_handlers, fn name, handlers ->
        Map.delete(handlers, name)
      end)

    %{state | tools: new_tools, tool_handlers: new_handlers}
  end

  defp add_tool(tools, name) do
    # Add a default tool by name
    if Enum.any?(tools, &tool_matches?(&1, name)) do
      tools
    else
      case name do
        "shell" -> tools ++ [Tools.Shell.spec()]
        "view_image" -> tools ++ [Tools.ViewImage.spec()]
        "read_file" -> tools ++ [Tools.Files.read_file_spec()]
        "list_dir" -> tools ++ [Tools.Files.list_dir_spec()]
        "grep_files" -> tools ++ [Tools.Files.grep_files_spec()]
        "apply_patch" -> tools ++ [Tools.ApplyPatch.spec()]
        _ -> tools
      end
    end
  end

  defp remove_tool_spec(tools, name) do
    Enum.reject(tools, &tool_matches?(&1, name))
  end

  defp filter_tools(nil), do: default_tools()

  defp filter_tools(names) when is_list(names) do
    # Always include exec tools and blackboard for sub-agents
    base = [
      Tools.Exec.exec_command_spec(),
      Tools.Exec.write_stdin_spec(),
      %{"type" => "local_shell"},
      Tools.SubAgent.blackboard_write_spec(),
      Tools.SubAgent.blackboard_read_spec()
    ]

    extra =
      Enum.flat_map(names, fn name ->
        case name do
          "shell" -> [Tools.Shell.spec()]
          "view_image" -> [Tools.ViewImage.spec()]
          # Already included
          "local_shell" -> []
          # Already included
          "exec_command" -> []
          # Already included
          "write_stdin" -> []
          "read_file" -> [Tools.Files.read_file_spec()]
          "list_dir" -> [Tools.Files.list_dir_spec()]
          "grep_files" -> [Tools.Files.grep_files_spec()]
          "apply_patch" -> [Tools.ApplyPatch.spec()]
          # Already included
          "blackboard_write" -> []
          # Already included
          "blackboard_read" -> []
          _ -> []
        end
      end)

    uniq_tools(base ++ extra)
  end

  defp tool_matches?(tool, name), do: tool_key(tool) == name

  defp tool_key(tool) do
    Map.get(tool, "name") || Map.get(tool, :name) || Map.get(tool, "type") || Map.get(tool, :type)
  end

  defp normalize_tool_spec(spec) when is_map(spec) do
    normalized =
      Enum.reduce(spec, %{}, fn {key, value}, acc ->
        Map.put(acc, to_string(key), value)
      end)

    case Map.get(normalized, "name") do
      name when is_binary(name) and name != "" -> {:ok, normalized, name}
      _ -> {:error, :invalid_tool_spec}
    end
  end

  defp normalize_tool_spec(_), do: {:error, :invalid_tool_spec}

  defp uniq_tools(tools) do
    Enum.uniq_by(tools, &tool_key/1)
  end

  defp build_instructions(nil, cwd) do
    String.replace(@default_system_prompt, "{{cwd}}", cwd)
  end

  defp build_instructions(custom, cwd) do
    String.replace(custom, "{{cwd}}", cwd)
  end

  defp default_tools do
    uniq_tools([
      # UnifiedExec-style session tools (port-backed stdio)
      Tools.Exec.exec_command_spec(),
      Tools.Exec.write_stdin_spec(),
      # Also keep local_shell for backward compatibility
      %{"type" => "local_shell"},
      Tools.Files.read_file_spec(),
      Tools.Files.list_dir_spec(),
      Tools.Files.grep_files_spec(),
      Tools.ApplyPatch.spec(),
      Tools.ViewImage.spec(),
      Tools.SubAgent.spawn_spec(),
      Tools.SubAgent.send_spec(),
      Tools.SubAgent.wait_spec(),
      Tools.SubAgent.blackboard_write_spec(),
      Tools.SubAgent.blackboard_read_spec(),
      Tools.SubAgent.kill_spec()
    ])
  end

  defp config_summary(state) do
    %{
      model: state.model,
      reasoning: state.reasoning,
      cwd: state.cwd,
      tools: Enum.map(state.tools, fn t -> tool_key(t) end)
    }
  end

  defp store_enabled? do
    Code.ensure_loaded?(EchsStore) and EchsStore.enabled?()
  end

  defp persist_thread(state) do
    if store_enabled?() do
      tools_json =
        try do
          Jason.encode!(state.tools)
        rescue
          Jason.EncodeError -> "[]"
        end

      _ =
        EchsStore.upsert_thread(%{
          thread_id: state.thread_id,
          parent_thread_id: state.parent_thread_id,
          created_at_ms: state.created_at_ms,
          last_activity_at_ms: state.last_activity_at_ms,
          model: state.model,
          reasoning: state.reasoning,
          cwd: state.cwd,
          instructions: state.instructions,
          tools_json: tools_json,
          coordination_mode: Atom.to_string(state.coordination_mode),
          history_count: length(state.history_items)
        })

      :ok
    else
      :ok
    end
  end

  defp persist_message(state, message_id) when is_binary(message_id) and message_id != "" do
    if store_enabled?() do
      meta = Map.get(state.message_log, message_id)

      if is_map(meta) do
        _ =
          EchsStore.upsert_message(state.thread_id, message_id, %{
            status: to_string(meta.status),
            enqueued_at_ms: meta.enqueued_at_ms,
            started_at_ms: meta.started_at_ms,
            completed_at_ms: meta.completed_at_ms,
            history_start: meta.history_start,
            history_end: meta.history_end,
            error: format_message_error(meta.error),
            request_json: meta.request_json
          })

        _ = persist_thread(state)
        :ok
      else
        :ok
      end
    else
      :ok
    end
  end

  defp persist_message(_state, _message_id), do: :ok

  defp format_message_error(nil), do: nil
  defp format_message_error(err) when is_binary(err), do: err
  defp format_message_error(err), do: inspect(err)

  defp append_history_items(state, items) when is_list(items) do
    case items do
      [] ->
        state

      _ ->
        next = %{state | history_items: state.history_items ++ items} |> touch()

        if store_enabled?() do
          _ = EchsStore.append_items(state.thread_id, state.current_message_id, items)
        end

        next
    end
  end

  defp append_history_items(state, _items), do: state

  defp expand_uploads_for_api(items) when is_list(items) do
    Enum.map(items, &expand_uploads_item/1)
  end

  defp expand_uploads_for_api(other), do: other

  defp expand_uploads_item(%{"type" => "message"} = item) do
    Map.update(item, "content", [], fn content ->
      Enum.map(content, &expand_uploads_content_item/1)
    end)
  end

  defp expand_uploads_item(item), do: item

  defp expand_uploads_content_item(%{"type" => "input_image"} = item) do
    upload_id = item["upload_id"]
    image_url = item["image_url"]

    cond do
      is_binary(image_url) and image_url != "" ->
        item

      is_binary(upload_id) and upload_id != "" ->
        case EchsCore.Uploads.image_url(upload_id) do
          {:ok, url} ->
            item
            |> Map.put("image_url", url)
            |> Map.delete("upload_id")

          {:error, reason} ->
            raise "unable to load upload #{upload_id}: #{inspect(reason)}"
        end

      true ->
        item
    end
  end

  defp expand_uploads_content_item(item), do: item

  defp broadcast(state, event_type, data) do
    data =
      data
      |> maybe_put(:message_id, state.current_message_id)

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

    state =
      state
      |> remember_message_id(message_id)
      |> message_log_start(message_id, now, history_start)
      |> Map.put(:current_message_id, message_id)
      |> Map.put(:current_turn_started_at_ms, now)
      |> touch()

    _ = persist_message(state, message_id)
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
      |> touch()

    _ = persist_message(state, message_id)
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
    %{state | last_activity_at_ms: now_ms()}
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
end
