defmodule EchsCore.EventPipeline do
  @moduledoc """
  Runelog-backed event distribution pipeline.

  Replaces the v1 Phoenix.PubSub broadcast model with a system where:
  - Events are first persisted to the runelog (source of truth)
  - Lightweight notifications are broadcast via PubSub
  - Subscribers read events from the runelog (not from fanout copies)
  - Bounded buffers with gap signals handle slow consumers
  - `since_event_id` reads enable resume without duplicates

  ## Architecture

      Producer (TurnEngine/ToolRouter)
          │
          ▼
      RunelogWriter.append()  ← durable
          │
          ▼
      PubSub.broadcast(:rune_appended, event_id)  ← lightweight notification
          │
          ▼
      Subscribers read from RunelogReader  ← no data in fanout

  ## Per-Conversation Topics

  Each conversation has a topic: `"conversation:<conversation_id>"`.
  Subscribers receive `{:rune_appended, conversation_id, event_id}` notifications.
  """

  alias EchsCore.Rune.{Schema, RunelogWriter, RunelogReader}

  @pubsub EchsCore.PubSub

  @doc """
  Publish a rune to the event pipeline.

  1. Appends the rune to the runelog (durable)
  2. Broadcasts a lightweight notification to subscribers

  Returns `{:ok, event_id}` on success.
  """
  @spec publish(GenServer.server(), Schema.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def publish(writer, %Schema{} = rune) do
    case RunelogWriter.append(writer, rune) do
      {:ok, event_id} ->
        notify(rune.conversation_id, event_id)
        {:ok, event_id}

      error ->
        error
    end
  end

  @doc """
  Publish a batch of runes atomically.
  """
  @spec publish_batch(GenServer.server(), [Schema.t()]) ::
          {:ok, Range.t()} | {:error, term()}
  def publish_batch(writer, runes) when is_list(runes) do
    case RunelogWriter.append_batch(writer, runes) do
      {:ok, range} ->
        if runes != [] do
          conv_id = hd(runes).conversation_id
          notify(conv_id, range.last)
        end

        {:ok, range}

      error ->
        error
    end
  end

  @doc """
  Subscribe to notifications for a conversation.
  Subscriber will receive `{:rune_appended, conversation_id, event_id}` messages.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(conversation_id))
  rescue
    ArgumentError -> {:error, :pubsub_not_started}
  end

  @doc """
  Unsubscribe from a conversation's notifications.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(conversation_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(conversation_id))
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Read events from the runelog since a given event_id (exclusive).
  Returns up to `limit` runes. Used by subscribers to fetch events
  after receiving a notification.

  If the requested event_id is before the earliest available event,
  a `{:gap, earliest_available_id}` signal is prepended.
  """
  @spec read_since(String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, [Schema.t()]} | {:gap, non_neg_integer(), [Schema.t()]} | {:error, term()}
  def read_since(segment_path, since_event_id, limit, _opts \\ []) do
    case RunelogReader.open(segment_path) do
      {:ok, reader} ->
        {runes, _reader} = RunelogReader.backfill(reader, since_event_id, limit)
        RunelogReader.close(reader)

        case runes do
          [first | _] when first.event_id > since_event_id + 1 ->
            # There's a gap — some events were compacted or unavailable
            {:gap, first.event_id, runes}

          _ ->
            {:ok, runes}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp topic(conversation_id), do: "conversation:#{conversation_id}"

  defp notify(conversation_id, event_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(conversation_id),
      {:rune_appended, conversation_id, event_id}
    )
  end
end
