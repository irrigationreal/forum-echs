defmodule EchsCore.EventPipeline.Subscriber do
  @moduledoc """
  Stateful subscriber for the event pipeline.

  Manages a cursor position and bounded buffer for a single client's
  subscription to a conversation. Handles:

  - Cursor tracking (last seen event_id)
  - Bounded buffering (configurable max pending notifications)
  - Gap detection and signaling
  - Visibility filtering

  ## Usage

      {:ok, sub} = Subscriber.new("conv_123",
        segment_path: "/path/to/segment.seg",
        since_event_id: 0,
        visibility: :public,
        max_buffer: 1000
      )

      # On receiving {:rune_appended, _, event_id} notification:
      {:ok, runes, sub} = Subscriber.poll(sub)

  """

  alias EchsCore.Rune.{Schema, RunelogReader}

  defstruct [
    :conversation_id,
    :segment_path,
    :cursor,
    :visibility,
    :max_buffer,
    :pending_count
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          segment_path: String.t(),
          cursor: non_neg_integer(),
          visibility: Schema.visibility(),
          max_buffer: non_neg_integer(),
          pending_count: non_neg_integer()
        }

  @default_max_buffer 1_000
  @default_poll_limit 100

  @doc """
  Create a new subscriber.

  Options:
    * `:segment_path` — path to the runelog segment (required)
    * `:since_event_id` — start cursor (default: 0, meaning read from beginning)
    * `:visibility` — visibility filter (default: :public)
    * `:max_buffer` — max pending notifications before gap signal (default: 1000)
  """
  @spec new(String.t(), keyword()) :: {:ok, t()}
  def new(conversation_id, opts) do
    {:ok,
     %__MODULE__{
       conversation_id: conversation_id,
       segment_path: Keyword.fetch!(opts, :segment_path),
       cursor: Keyword.get(opts, :since_event_id, 0),
       visibility: Keyword.get(opts, :visibility, :public),
       max_buffer: Keyword.get(opts, :max_buffer, @default_max_buffer),
       pending_count: 0
     }}
  end

  @doc """
  Notify the subscriber that new events are available.
  Increments the pending counter.
  """
  @spec notify(t()) :: t()
  def notify(%__MODULE__{} = sub) do
    %{sub | pending_count: sub.pending_count + 1}
  end

  @doc """
  Poll for new events since the subscriber's cursor.
  Returns filtered events and updates the cursor.

  Returns:
    * `{:ok, runes, subscriber}` — new events available
    * `{:gap, earliest_id, runes, subscriber}` — gap detected, some events missing
    * `{:empty, subscriber}` — no new events
  """
  @spec poll(t(), keyword()) :: {:ok, [Schema.t()], t()} | {:gap, non_neg_integer(), [Schema.t()], t()} | {:empty, t()}
  def poll(%__MODULE__{} = sub, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_poll_limit)

    case RunelogReader.open(sub.segment_path) do
      {:ok, reader} ->
        {runes, _reader} = RunelogReader.backfill(reader, sub.cursor, limit)
        RunelogReader.close(reader)

        filtered = Schema.filter_visibility(runes, sub.visibility)

        case filtered do
          [] ->
            {:empty, %{sub | pending_count: 0}}

          _ ->
            last_eid = List.last(filtered).event_id
            new_sub = %{sub | cursor: last_eid, pending_count: 0}

            first_eid = hd(filtered).event_id

            if first_eid > sub.cursor + 1 do
              {:gap, first_eid, filtered, new_sub}
            else
              {:ok, filtered, new_sub}
            end
        end

      {:error, _reason} ->
        {:empty, sub}
    end
  end

  @doc """
  Check if the subscriber has exceeded its buffer limit.
  When true, the client should be warned about potential gaps.
  """
  @spec buffer_exceeded?(t()) :: boolean()
  def buffer_exceeded?(%__MODULE__{pending_count: count, max_buffer: max}) do
    count > max
  end

  @doc """
  Get the current cursor position.
  """
  @spec cursor(t()) :: non_neg_integer()
  def cursor(%__MODULE__{cursor: c}), do: c
end
