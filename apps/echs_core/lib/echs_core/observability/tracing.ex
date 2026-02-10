defmodule EchsCore.Observability.Tracing do
  @moduledoc """
  Tracing spans for turns, provider calls, and tool invocations.

  Provides structured tracing with:
  - Unique trace/span IDs
  - Parent-child span relationships
  - Duration tracking
  - Metadata attachment
  - Correlation IDs linking spans to runes

  ## Usage

      span = Tracing.start_span("turn.execute", %{conversation_id: "conv_123"})
      # ... do work ...
      span = Tracing.end_span(span)
  """

  @type span :: %{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t(),
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          status: :running | :ok | :error,
          metadata: map(),
          events: [span_event()]
        }

  @type span_event :: %{
          name: String.t(),
          timestamp_ms: non_neg_integer(),
          metadata: map()
        }

  @doc "Start a new root span."
  @spec start_span(String.t(), map()) :: span()
  def start_span(name, metadata \\ %{}) do
    now = System.system_time(:millisecond)

    %{
      trace_id: generate_trace_id(),
      span_id: generate_span_id(),
      parent_span_id: nil,
      name: name,
      start_ms: now,
      end_ms: nil,
      duration_ms: nil,
      status: :running,
      metadata: metadata,
      events: []
    }
  end

  @doc "Start a child span under a parent."
  @spec start_child_span(span(), String.t(), map()) :: span()
  def start_child_span(parent, name, metadata \\ %{}) do
    now = System.system_time(:millisecond)

    %{
      trace_id: parent.trace_id,
      span_id: generate_span_id(),
      parent_span_id: parent.span_id,
      name: name,
      start_ms: now,
      end_ms: nil,
      duration_ms: nil,
      status: :running,
      metadata: metadata,
      events: []
    }
  end

  @doc "End a span and compute duration."
  @spec end_span(span(), :ok | :error) :: span()
  def end_span(span, status \\ :ok) do
    now = System.system_time(:millisecond)

    %{span |
      end_ms: now,
      duration_ms: now - span.start_ms,
      status: status
    }
  end

  @doc "Add an event to a span."
  @spec add_event(span(), String.t(), map()) :: span()
  def add_event(span, event_name, metadata \\ %{}) do
    event = %{
      name: event_name,
      timestamp_ms: System.system_time(:millisecond),
      metadata: metadata
    }

    %{span | events: span.events ++ [event]}
  end

  @doc "Add metadata to a span."
  @spec add_metadata(span(), map()) :: span()
  def add_metadata(span, new_metadata) do
    %{span | metadata: Map.merge(span.metadata, new_metadata)}
  end

  @doc "Get the correlation ID for linking spans to runes."
  @spec correlation_id(span()) :: String.t()
  def correlation_id(span) do
    "#{span.trace_id}:#{span.span_id}"
  end

  @doc "Format a span as a structured log entry."
  @spec to_log_entry(span()) :: map()
  def to_log_entry(span) do
    %{
      trace_id: span.trace_id,
      span_id: span.span_id,
      parent_span_id: span.parent_span_id,
      name: span.name,
      duration_ms: span.duration_ms,
      status: span.status,
      metadata: span.metadata,
      event_count: length(span.events)
    }
  end

  @doc "Emit a telemetry event for the span."
  @spec emit_telemetry(span()) :: :ok
  def emit_telemetry(span) do
    measurements = %{
      duration_ms: span.duration_ms || 0,
      event_count: length(span.events)
    }

    metadata = Map.merge(span.metadata, %{
      trace_id: span.trace_id,
      span_id: span.span_id,
      name: span.name,
      status: span.status
    })

    :telemetry.execute(
      [:echs, :trace, :span],
      measurements,
      metadata
    )

    :ok
  end

  # --- Internal ---

  defp generate_trace_id, do: "trc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp generate_span_id, do: "spn_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
