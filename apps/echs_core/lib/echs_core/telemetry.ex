defmodule EchsCore.Telemetry do
  @moduledoc """
  Telemetry events for ECHS observability.

  Emits `:telemetry.execute/3` at key points in the system lifecycle.

  ## Events

  ### Turn lifecycle

  * `[:echs, :turn, :start]` - emitted when a turn begins
    * Measurements: `%{system_time: integer}`
    * Metadata: `%{thread_id: String.t(), message_id: String.t(), model: String.t()}`

  * `[:echs, :turn, :stop]` - emitted when a turn completes
    * Measurements: `%{duration_ms: integer}`
    * Metadata: `%{thread_id: String.t(), message_id: String.t(), model: String.t(), status: atom()}`

  * `[:echs, :turn, :exception]` - emitted when a turn fails
    * Measurements: `%{duration_ms: integer}`
    * Metadata: `%{thread_id: String.t(), message_id: String.t(), model: String.t(), error: term()}`

  ### Tool execution

  * `[:echs, :tool, :start]` - emitted when a tool call begins
    * Measurements: `%{system_time: integer}`
    * Metadata: `%{thread_id: String.t(), tool_name: String.t(), call_id: String.t()}`

  * `[:echs, :tool, :stop]` - emitted when a tool call completes
    * Measurements: `%{duration_ms: integer}`
    * Metadata: `%{thread_id: String.t(), tool_name: String.t(), call_id: String.t()}`

  ### API requests

  * `[:echs, :api, :request]` - emitted after an API response is received
    * Measurements: `%{duration_ms: integer, input_tokens: integer | nil, output_tokens: integer | nil}`
    * Metadata: `%{model: String.t(), status: atom()}`

  ### Limiter

  * `[:echs, :limiter, :acquire]` - emitted when a turn slot is acquired or queued
    * Measurements: `%{queue_depth: integer}`
    * Metadata: `%{result: :ok | :wait}`

  ### Sub-agents

  * `[:echs, :subagent, :spawn]` - emitted when a sub-agent is spawned
    * Measurements: `%{child_count: integer}`
    * Metadata: `%{parent_thread_id: String.t(), child_thread_id: String.t()}`

  * `[:echs, :subagent, :terminate]` - emitted when a sub-agent terminates
    * Measurements: `%{child_count: integer}`
    * Metadata: `%{parent_thread_id: String.t(), child_thread_id: String.t()}`
  """

  # -------------------------------------------------------------------
  # Turn events
  # -------------------------------------------------------------------

  @doc "Emit turn start event."
  def turn_start(thread_id, message_id, model) do
    :telemetry.execute(
      [:echs, :turn, :start],
      %{system_time: System.system_time(:millisecond)},
      %{thread_id: thread_id, message_id: message_id, model: model}
    )
  end

  @doc "Emit turn stop event."
  def turn_stop(thread_id, message_id, model, status, duration_ms) do
    :telemetry.execute(
      [:echs, :turn, :stop],
      %{duration_ms: duration_ms},
      %{thread_id: thread_id, message_id: message_id, model: model, status: status}
    )
  end

  @doc "Emit turn exception event."
  def turn_exception(thread_id, message_id, model, error, duration_ms) do
    :telemetry.execute(
      [:echs, :turn, :exception],
      %{duration_ms: duration_ms},
      %{thread_id: thread_id, message_id: message_id, model: model, error: error}
    )
  end

  # -------------------------------------------------------------------
  # Tool events
  # -------------------------------------------------------------------

  @doc "Emit tool start event."
  def tool_start(thread_id, tool_name, call_id) do
    :telemetry.execute(
      [:echs, :tool, :start],
      %{system_time: System.system_time(:millisecond)},
      %{thread_id: thread_id, tool_name: tool_name, call_id: call_id}
    )
  end

  @doc "Emit tool stop event."
  def tool_stop(thread_id, tool_name, call_id, duration_ms) do
    :telemetry.execute(
      [:echs, :tool, :stop],
      %{duration_ms: duration_ms},
      %{thread_id: thread_id, tool_name: tool_name, call_id: call_id}
    )
  end

  # -------------------------------------------------------------------
  # API events
  # -------------------------------------------------------------------

  @doc "Emit API request event."
  def api_request(model, status, duration_ms, input_tokens \\ nil, output_tokens \\ nil) do
    :telemetry.execute(
      [:echs, :api, :request],
      %{duration_ms: duration_ms, input_tokens: input_tokens, output_tokens: output_tokens},
      %{model: model, status: status}
    )
  end

  # -------------------------------------------------------------------
  # Limiter events
  # -------------------------------------------------------------------

  @doc "Emit limiter acquire event."
  def limiter_acquire(result, queue_depth) do
    :telemetry.execute(
      [:echs, :limiter, :acquire],
      %{queue_depth: queue_depth},
      %{result: result}
    )
  end

  # -------------------------------------------------------------------
  # Sub-agent events
  # -------------------------------------------------------------------

  @doc "Emit sub-agent spawn event."
  def subagent_spawn(parent_thread_id, child_thread_id, child_count) do
    :telemetry.execute(
      [:echs, :subagent, :spawn],
      %{child_count: child_count},
      %{parent_thread_id: parent_thread_id, child_thread_id: child_thread_id}
    )
  end

  @doc "Emit sub-agent terminate event."
  def subagent_terminate(parent_thread_id, child_thread_id, child_count) do
    :telemetry.execute(
      [:echs, :subagent, :terminate],
      %{child_count: child_count},
      %{parent_thread_id: parent_thread_id, child_thread_id: child_thread_id}
    )
  end

  # -------------------------------------------------------------------
  # Event buffer events
  # -------------------------------------------------------------------

  @doc "Emit event buffer truncation event."
  def event_buffer_truncated(thread_id, dropped_count) do
    :telemetry.execute(
      [:echs, :event_buffer, :truncated],
      %{dropped_count: dropped_count},
      %{thread_id: thread_id}
    )
  end
end
