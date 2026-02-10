defmodule EchsCore.WebSocket.Handler do
  @moduledoc """
  WebSocket multiplex protocol handler.

  Supports multiple conversations per connection with:
  - `subscribe` — subscribe to conversation events with optional resume
  - `unsubscribe` — stop receiving events for a conversation
  - `post_message` — send a user message to a conversation
  - `approve` — approve a pending tool invocation
  - `interrupt` — interrupt the current turn
  - Versioned messages with `request_id` ACKs
  - Idempotency keys on mutating operations

  ## Wire Protocol

  All messages are JSON objects with:

      {
        "type": "<operation>",
        "request_id": "<optional uuid for ACK>",
        "idempotency_key": "<optional for mutations>",
        ...operation-specific fields
      }

  Server responses:

      {
        "type": "ack",
        "request_id": "<echoed>",
        "status": "ok" | "error",
        "error": "<optional message>"
      }

  Event delivery:

      {
        "type": "event",
        "conversation_id": "<id>",
        "rune": { ...serialized rune... }
      }

  Gap signal:

      {
        "type": "gap",
        "conversation_id": "<id>",
        "earliest_available": <event_id>
      }
  """

  require Logger

  alias EchsCore.Rune.Schema

  @type conn_state :: %{
          subscriptions: %{optional(String.t()) => subscription()},
          idempotency_cache: %{optional(String.t()) => term()},
          send_fn: (binary() -> :ok)
        }

  @type subscription :: %{
          conversation_id: String.t(),
          cursor: non_neg_integer(),
          visibility: Schema.visibility()
        }

  @doc """
  Initialize connection state.
  """
  @spec init((binary() -> :ok)) :: conn_state()
  def init(send_fn) do
    %{
      subscriptions: %{},
      idempotency_cache: %{},
      send_fn: send_fn
    }
  end

  @doc """
  Handle an incoming WebSocket text frame.
  Returns `{:ok, conn_state}` or `{:error, reason, conn_state}`.
  """
  @spec handle_message(binary(), conn_state()) :: {:ok, conn_state()} | {:error, term(), conn_state()}
  def handle_message(data, state) do
    case Jason.decode(data) do
      {:ok, msg} -> dispatch(msg, state)
      {:error, _} -> send_error(state, nil, "invalid JSON")
    end
  end

  @doc """
  Handle a PubSub notification for a subscribed conversation.
  Delivers events to the client.
  """
  @spec handle_notification(String.t(), non_neg_integer(), conn_state()) :: conn_state()
  def handle_notification(conversation_id, _event_id, state) do
    case Map.get(state.subscriptions, conversation_id) do
      nil ->
        state

      _sub ->
        # In a full implementation, we'd read from the runelog here.
        # For now, the notification is forwarded as-is.
        state
    end
  end

  @doc """
  Deliver a rune event to the client for a subscribed conversation.
  """
  @spec deliver_event(conn_state(), String.t(), Schema.t()) :: conn_state()
  def deliver_event(state, conversation_id, %Schema{} = rune) do
    case Map.get(state.subscriptions, conversation_id) do
      nil ->
        state

      sub ->
        # Check visibility
        if visible?(rune, sub.visibility) do
          msg = %{
            "type" => "event",
            "conversation_id" => conversation_id,
            "rune" => Schema.encode(rune)
          }

          state.send_fn.(Jason.encode!(msg))
          update_cursor(state, conversation_id, rune.event_id)
        else
          state
        end
    end
  end

  @doc """
  Send a gap signal to the client.
  """
  @spec deliver_gap(conn_state(), String.t(), non_neg_integer()) :: conn_state()
  def deliver_gap(state, conversation_id, earliest_available) do
    msg = %{
      "type" => "gap",
      "conversation_id" => conversation_id,
      "earliest_available" => earliest_available
    }

    state.send_fn.(Jason.encode!(msg))
    state
  end

  # -------------------------------------------------------------------
  # Message dispatch
  # -------------------------------------------------------------------

  defp dispatch(%{"type" => "subscribe"} = msg, state) do
    conversation_id = msg["conversation_id"]
    since_event_id = msg["since_event_id"] || 0
    visibility = parse_visibility(msg["visibility"])
    request_id = msg["request_id"]

    if conversation_id do
      # Subscribe to PubSub
      EchsCore.EventPipeline.subscribe(conversation_id)

      sub = %{
        conversation_id: conversation_id,
        cursor: since_event_id,
        visibility: visibility
      }

      subs = Map.put(state.subscriptions, conversation_id, sub)
      state = %{state | subscriptions: subs}

      send_ack(state, request_id, "ok")
    else
      send_error(state, request_id, "conversation_id required")
    end
  end

  defp dispatch(%{"type" => "unsubscribe"} = msg, state) do
    conversation_id = msg["conversation_id"]
    request_id = msg["request_id"]

    if conversation_id do
      EchsCore.EventPipeline.unsubscribe(conversation_id)
      subs = Map.delete(state.subscriptions, conversation_id)
      state = %{state | subscriptions: subs}
      send_ack(state, request_id, "ok")
    else
      send_error(state, request_id, "conversation_id required")
    end
  end

  defp dispatch(%{"type" => "post_message"} = msg, state) do
    conversation_id = msg["conversation_id"]
    content = msg["content"]
    request_id = msg["request_id"]
    idempotency_key = msg["idempotency_key"]

    cond do
      conversation_id == nil ->
        send_error(state, request_id, "conversation_id required")

      content == nil ->
        send_error(state, request_id, "content required")

      idempotency_key && Map.has_key?(state.idempotency_cache, idempotency_key) ->
        # Return cached response for idempotent retry
        cached = Map.get(state.idempotency_cache, idempotency_key)
        send_ack_with_data(state, request_id, "ok", cached)

      true ->
        # In a full implementation, this would dispatch to the conversation
        # For now, record the idempotency key and send ACK
        result = %{"message_id" => "msg_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}

        state =
          if idempotency_key do
            %{state | idempotency_cache: Map.put(state.idempotency_cache, idempotency_key, result)}
          else
            state
          end

        send_ack_with_data(state, request_id, "ok", result)
    end
  end

  defp dispatch(%{"type" => "approve"} = msg, state) do
    request_id = msg["request_id"]
    call_id = msg["call_id"]
    decision = msg["decision"] || "approved"

    if call_id do
      # In a full implementation, this would route to the ToolRouter
      send_ack_with_data(state, request_id, "ok", %{"call_id" => call_id, "decision" => decision})
    else
      send_error(state, request_id, "call_id required")
    end
  end

  defp dispatch(%{"type" => "interrupt"} = msg, state) do
    conversation_id = msg["conversation_id"]
    request_id = msg["request_id"]

    if conversation_id do
      # In a full implementation, this would interrupt the conversation's active turn
      send_ack(state, request_id, "ok")
    else
      send_error(state, request_id, "conversation_id required")
    end
  end

  defp dispatch(msg, state) do
    request_id = msg["request_id"]
    send_error(state, request_id, "unknown message type: #{msg["type"]}")
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp send_ack(state, request_id, status) do
    msg = %{"type" => "ack", "status" => status}
    msg = if request_id, do: Map.put(msg, "request_id", request_id), else: msg
    state.send_fn.(Jason.encode!(msg))
    {:ok, state}
  end

  defp send_ack_with_data(state, request_id, status, data) do
    msg = %{"type" => "ack", "status" => status, "data" => data}
    msg = if request_id, do: Map.put(msg, "request_id", request_id), else: msg
    state.send_fn.(Jason.encode!(msg))
    {:ok, state}
  end

  defp send_error(state, request_id, error) do
    msg = %{"type" => "ack", "status" => "error", "error" => error}
    msg = if request_id, do: Map.put(msg, "request_id", request_id), else: msg
    state.send_fn.(Jason.encode!(msg))
    {:error, error, state}
  end

  defp parse_visibility("internal"), do: :internal
  defp parse_visibility("secret"), do: :secret
  defp parse_visibility(_), do: :public

  defp visible?(_rune, :secret), do: true
  defp visible?(rune, :internal), do: rune.visibility in [:public, :internal]
  defp visible?(rune, :public), do: rune.visibility == :public

  defp update_cursor(state, conversation_id, event_id) do
    case Map.get(state.subscriptions, conversation_id) do
      nil ->
        state

      sub ->
        updated = %{sub | cursor: max(sub.cursor, event_id)}
        %{state | subscriptions: Map.put(state.subscriptions, conversation_id, updated)}
    end
  end
end
