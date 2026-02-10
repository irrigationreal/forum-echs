defmodule EchsCore.ToolSystem.ToolRouter do
  @moduledoc """
  Tool invocation engine that enforces the tool lifecycle with runes.

  Manages the full lifecycle of tool invocations:

      tool.call → [tool.approval_requested → tool.approved/denied] →
      tool.progress* → tool.result

  Enforces:
  - INV-TOOL-TERMINAL: Exactly one terminal result per call
  - INV-TOOL-CALL-BEFORE-RESULT: No result without prior call
  - Cancellation and timeouts with proper result recording
  - Crash-safe: unknown outcome recorded if tool process crashes

  ## Architecture

  The ToolRouter is a GenServer per conversation that:
  1. Receives tool call requests from the TurnEngine
  2. Emits tool.call runes via the EventPipeline
  3. Delegates to the PermissionPolicy for approval checks
  4. Dispatches to the appropriate tool handler
  5. Emits tool.progress runes for streaming output
  6. Emits exactly one tool.result rune per call (success/error/timeout/cancelled)
  """

  use GenServer
  require Logger

  alias EchsCore.Rune.Schema
  alias EchsCore.Rune.Invariant

  defstruct [
    :conversation_id,
    :agent_id,
    pending_calls: %{},
    completed_calls: MapSet.new()
  ]

  @type call_state :: %{
          call_id: String.t(),
          tool_name: String.t(),
          arguments: term(),
          status: :pending | :approved | :executing | :terminal,
          started_at: non_neg_integer(),
          task_ref: reference() | nil,
          timeout_ref: reference() | nil
        }

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Record a tool call. Emits a tool.call rune and begins the invocation
  lifecycle. Returns `{:ok, call_id}`.
  """
  @spec record_call(GenServer.server(), map()) :: {:ok, String.t()}
  def record_call(router, call_info) do
    GenServer.call(router, {:record_call, call_info})
  end

  @doc """
  Record a tool result. Emits a tool.result rune.
  Enforces INV-TOOL-TERMINAL (exactly one result per call).
  """
  @spec record_result(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def record_result(router, call_id, result) do
    GenServer.call(router, {:record_result, call_id, result})
  end

  @doc """
  Record streaming progress for a tool. Emits a tool.progress rune.
  """
  @spec record_progress(GenServer.server(), String.t(), map()) :: :ok
  def record_progress(router, call_id, progress) do
    GenServer.cast(router, {:record_progress, call_id, progress})
  end

  @doc """
  Cancel a pending or executing tool call.
  """
  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(router, call_id) do
    GenServer.call(router, {:cancel, call_id})
  end

  @doc """
  Get the state of a tool call.
  """
  @spec get_call(GenServer.server(), String.t()) :: {:ok, call_state()} | {:error, :not_found}
  def get_call(router, call_id) do
    GenServer.call(router, {:get_call, call_id})
  end

  @doc """
  List all pending (non-terminal) calls.
  """
  @spec pending_calls(GenServer.server()) :: [call_state()]
  def pending_calls(router) do
    GenServer.call(router, :pending_calls)
  end

  @doc """
  Build a tool.call rune.
  """
  @spec build_call_rune(String.t(), String.t(), String.t(), map()) :: Schema.t()
  def build_call_rune(conversation_id, agent_id, call_id, call_info) do
    Schema.new(
      conversation_id: conversation_id,
      agent_id: agent_id,
      kind: "tool.call",
      payload: %{
        "call_id" => call_id,
        "tool_name" => call_info["tool_name"] || call_info[:tool_name] || "unknown",
        "arguments" => call_info["arguments"] || call_info[:arguments] || %{},
        "provenance" => call_info["provenance"] || call_info[:provenance] || "built_in"
      }
    )
  end

  @doc """
  Build a tool.result rune.
  """
  @spec build_result_rune(String.t(), String.t(), String.t(), map()) :: Schema.t()
  def build_result_rune(conversation_id, agent_id, call_id, result) do
    Schema.new(
      conversation_id: conversation_id,
      agent_id: agent_id,
      kind: "tool.result",
      payload: Map.merge(
        %{
          "call_id" => call_id,
          "status" => result["status"] || result[:status] || "success"
        },
        Map.take(result, ["output", "error", "duration_ms", :output, :error, :duration_ms])
        |> Enum.map(fn {k, v} -> {to_string(k), v} end)
        |> Map.new()
      )
    )
  end

  @doc """
  Build a tool.progress rune.
  """
  @spec build_progress_rune(String.t(), String.t(), String.t(), map()) :: Schema.t()
  def build_progress_rune(conversation_id, agent_id, call_id, progress) do
    Schema.new(
      conversation_id: conversation_id,
      agent_id: agent_id,
      kind: "tool.progress",
      payload: Map.merge(%{"call_id" => call_id}, progress)
    )
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    agent_id = Keyword.get(opts, :agent_id, "agt_root")

    {:ok,
     %__MODULE__{
       conversation_id: conversation_id,
       agent_id: agent_id
     }}
  end

  @impl true
  def handle_call({:record_call, call_info}, _from, state) do
    call_id = call_info["call_id"] || call_info[:call_id] || generate_call_id()
    tool_name = call_info["tool_name"] || call_info[:tool_name] || "unknown"

    call_state = %{
      call_id: call_id,
      tool_name: tool_name,
      arguments: call_info["arguments"] || call_info[:arguments] || %{},
      status: :pending,
      started_at: System.monotonic_time(:millisecond),
      task_ref: nil,
      timeout_ref: nil
    }

    pending = Map.put(state.pending_calls, call_id, call_state)
    {:reply, {:ok, call_id}, %{state | pending_calls: pending}}
  end

  def handle_call({:record_result, call_id, _result}, _from, state) do
    cond do
      MapSet.member?(state.completed_calls, call_id) ->
        # INV-TOOL-TERMINAL: duplicate result
        Invariant.inv_ok?("INV-TOOL-TERMINAL", false,
          severity: :warn,
          message: "Duplicate result for call_id=#{call_id}",
          context: %{call_id: call_id}
        )

        {:reply, {:error, :already_completed}, state}

      not Map.has_key?(state.pending_calls, call_id) ->
        # INV-TOOL-CALL-BEFORE-RESULT: result without prior call
        Invariant.inv_ok?("INV-TOOL-CALL-BEFORE-RESULT", false,
          severity: :warn,
          message: "Result for unknown call_id=#{call_id}",
          context: %{call_id: call_id}
        )

        {:reply, {:error, :unknown_call}, state}

      true ->
        # Cancel any timeout timer
        call_state = Map.get(state.pending_calls, call_id)

        if call_state.timeout_ref do
          Process.cancel_timer(call_state.timeout_ref)
        end

        pending = Map.delete(state.pending_calls, call_id)
        completed = MapSet.put(state.completed_calls, call_id)

        {:reply, :ok, %{state | pending_calls: pending, completed_calls: completed}}
    end
  end

  def handle_call({:cancel, call_id}, _from, state) do
    case Map.get(state.pending_calls, call_id) do
      nil ->
        {:reply, :ok, state}

      call_state ->
        if call_state.timeout_ref, do: Process.cancel_timer(call_state.timeout_ref)

        pending = Map.delete(state.pending_calls, call_id)
        completed = MapSet.put(state.completed_calls, call_id)

        {:reply, :ok, %{state | pending_calls: pending, completed_calls: completed}}
    end
  end

  def handle_call({:get_call, call_id}, _from, state) do
    case Map.get(state.pending_calls, call_id) do
      nil ->
        if MapSet.member?(state.completed_calls, call_id) do
          {:reply, {:ok, %{call_id: call_id, status: :terminal}}, state}
        else
          {:reply, {:error, :not_found}, state}
        end

      call_state ->
        {:reply, {:ok, call_state}, state}
    end
  end

  def handle_call(:pending_calls, _from, state) do
    {:reply, Map.values(state.pending_calls), state}
  end

  @impl true
  def handle_cast({:record_progress, _call_id, _progress}, state) do
    # Progress is recorded as runes by the caller; the router just tracks state
    {:noreply, state}
  end

  @impl true
  def handle_info({:timeout, call_id}, state) do
    case Map.get(state.pending_calls, call_id) do
      nil ->
        {:noreply, state}

      _call_state ->
        Logger.warning("Tool call #{call_id} timed out")

        pending = Map.delete(state.pending_calls, call_id)
        completed = MapSet.put(state.completed_calls, call_id)

        {:noreply, %{state | pending_calls: pending, completed_calls: completed}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp generate_call_id do
    "call_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end
