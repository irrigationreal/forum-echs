defmodule EchsServer.Router do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias EchsServer.MessageContent
  alias EchsServer.{Conversations, JSON, Models}
  alias EchsStore.{Conversation, Message, Thread}

  plug(EchsServer.AuthPlug)

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["application/json", "multipart/form-data", "application/x-www-form-urlencoded"],
    json_decoder: Jason,
    length: 10_000_000
  )

  plug(:dispatch)

  get "/healthz" do
    {status, body} = EchsServer.HealthCheck.run()
    JSON.send_json(conn, status, body)
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, EchsServer.Metrics.prometheus_text())
  end

  get "/metrics/json" do
    JSON.send_json(conn, 200, EchsServer.Metrics.summary())
  end

  get "/v1/models" do
    JSON.send_json(conn, 200, Models.catalog())
  end

  get "/openapi.json" do
    JSON.send_json(conn, 200, EchsProtocol.V1.OpenAPI.spec())
  end

  # --- Uploads

  post "/v1/uploads" do
    conn = fetch_query_params(conn)
    params = conn.body_params || %{}
    inline? = parse_bool(conn.query_params["inline"] || params["inline"])

    case Map.get(params, "file") do
      %Plug.Upload{} = upload ->
        case EchsServer.Uploads.prepare_image(upload, inline: inline?) do
          {:ok, payload} ->
            JSON.send_json(conn, 201, payload)

          {:error, reason} ->
            JSON.send_error(conn, 400, "upload failed", %{reason: inspect(reason)})
        end

      _ ->
        JSON.send_error(conn, 400, "missing file", %{field: "file"})
    end
  end

  # --- Threads

  # --- Conversations

  post "/v1/conversations" do
    params = conn.body_params || %{}

    case Conversations.create(params) do
      {:ok, conversation} ->
        JSON.send_json(conn, 201, %{conversation: sanitize_conversation_record(conversation)})

      {:error, reason} ->
        JSON.send_error(conn, 400, "failed to create conversation", %{reason: inspect(reason)})
    end
  end

  get "/v1/conversations" do
    {:ok, conversations} = Conversations.list(limit: 200)

    JSON.send_json(conn, 200, %{
      conversations: Enum.map(conversations, &sanitize_conversation_record/1)
    })
  end

  get "/v1/conversations/:conversation_id" do
    case Conversations.get(conversation_id) do
      {:ok, conversation} ->
        JSON.send_json(conn, 200, %{conversation: sanitize_conversation_record(conversation)})

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")
    end
  end

  patch "/v1/conversations/:conversation_id" do
    params = conn.body_params || %{}

    case Conversations.update(conversation_id, params) do
      {:ok, conversation} ->
        JSON.send_json(conn, 200, %{conversation: sanitize_conversation_record(conversation)})

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")

      {:error, reason} ->
        JSON.send_error(conn, 400, "failed to update conversation", %{reason: inspect(reason)})
    end
  end

  get "/v1/conversations/:conversation_id/sessions" do
    {:ok, sessions} = Conversations.list_sessions(conversation_id)

    JSON.send_json(conn, 200, %{
      conversation_id: conversation_id,
      sessions: Enum.map(sessions, &sanitize_thread_record/1)
    })
  end

  get "/v1/conversations/:conversation_id/history" do
    conn = fetch_query_params(conn)
    offset = parse_int(conn.query_params["offset"], 0)
    limit = parse_int(conn.query_params["limit"], 5000)
    redact? = parse_bool(conn.query_params["redact"] || "1")

    case Conversations.list_history(conversation_id, offset: offset, limit: limit, redact?: redact?) do
      {:ok, resp} ->
        JSON.send_json(conn, 200, resp)

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")

      {:error, reason} ->
        JSON.send_error(conn, 500, "failed to load history", %{reason: inspect(reason)})
    end
  end

  post "/v1/conversations/:conversation_id/messages" do
    params = conn.body_params || %{}

    mode = params["mode"] || "queue"
    configure = normalize_config(params["configure"] || %{})
    message_id = params["message_id"]

    with :ok <- validate_id_optional("message_id", message_id),
         {:ok, content} <- extract_and_normalize_content(params) do
      opts =
        []
        |> Keyword.put(:mode, mode)
        |> Keyword.put(:configure, configure)
        |> maybe_put_kw(:message_id, message_id)

      case Conversations.enqueue_message(conversation_id, content, opts) do
        {:ok, %{thread_id: thread_id, message_id: message_id, compacted: compacted}} ->
          JSON.send_json(conn, 202, %{
            ok: true,
            conversation_id: conversation_id,
            thread_id: thread_id,
            message_id: message_id,
            compacted: compacted
          })

        {:error, :paused} ->
          JSON.send_error(conn, 409, "thread is paused")

        {:error, :not_found} ->
          JSON.send_error(conn, 404, "conversation not found")

        {:error, reason} ->
          JSON.send_error(conn, 500, "enqueue_message failed", %{reason: inspect(reason)})
      end
    end
  end

  post "/v1/conversations/:conversation_id/interrupt" do
    case Conversations.get_active_thread(conversation_id) do
      {:ok, thread_id} ->
        case safe_interrupt(thread_id) do
          :ok -> JSON.send_json(conn, 200, %{ok: true})
          {:error, :not_found} -> JSON.send_error(conn, 404, "thread not found")
        end

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")
    end
  end

  post "/v1/conversations/:conversation_id/pause" do
    case Conversations.get_active_thread(conversation_id) do
      {:ok, thread_id} ->
        case safe_pause(thread_id) do
          :ok -> JSON.send_json(conn, 200, %{ok: true})
          {:error, :not_found} -> JSON.send_error(conn, 404, "thread not found")
        end

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")
    end
  end

  post "/v1/conversations/:conversation_id/resume" do
    case Conversations.get_active_thread(conversation_id) do
      {:ok, thread_id} ->
        case safe_resume(thread_id) do
          :ok -> JSON.send_json(conn, 200, %{ok: true})
          {:error, :not_found} -> JSON.send_error(conn, 404, "thread not found")
        end

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")
    end
  end

  get "/v1/conversations/:conversation_id/events" do
    case Conversations.get(conversation_id) do
      {:ok, conversation} ->
        if conversation.active_thread_id do
          Conversations.stream_attach_thread(conversation_id, conversation.active_thread_id)
        end

        last_event_id = List.first(get_req_header(conn, "last-event-id"))

        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)
        |> stream_conversation_events(conversation_id, last_event_id)

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "conversation not found")
    end
  end

  post "/v1/threads" do
    params = conn.body_params || %{}
    tools = Map.get(params, "tools")
    toolsets = Map.get(params, "toolsets")

    opts =
      []
      |> maybe_put_kw(:thread_id, params["thread_id"])
      |> maybe_put_kw(:cwd, params["cwd"])
      |> maybe_put_kw(:model, params["model"])
      |> maybe_put_kw(:reasoning, params["reasoning"])
      |> maybe_put_kw(:instructions, params["instructions"])
      |> maybe_put_kw(:coordination_mode, parse_coordination(params["coordination_mode"]))

    case EchsCore.create_thread(opts) do
      {:ok, thread_id} ->
        _ = EchsServer.ThreadEventBuffer.ensure_started(thread_id)

        config =
          %{}
          |> maybe_put_config("tools", tools)
          |> maybe_put_config("toolsets", toolsets)

        if map_size(config) > 0 do
          :ok = EchsCore.configure_thread(thread_id, config)
        end

        JSON.send_json(conn, 201, %{thread_id: thread_id})

      {:error, reason} ->
        JSON.send_error(conn, 400, "failed to create thread", %{reason: inspect(reason)})
    end
  end

  get "/v1/threads" do
    ids =
      Registry.select(EchsCore.Registry, [
        {{:"$1", :_, :_}, [], [:"$1"]}
      ])

    live =
      ids
      |> Enum.map(fn id ->
        case safe_get_state(id) do
          {:ok, state} -> {id, sanitize_state(state)}
          :not_found -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    stored =
      if store_enabled?() do
        EchsStore.list_threads(limit: 200)
        |> Enum.reduce([], fn %Thread{} = t, acc ->
          if Map.has_key?(live, t.thread_id) do
            acc
          else
            [sanitize_thread_record(t) | acc]
          end
        end)
        |> Enum.reverse()
      else
        []
      end

    threads = Map.values(live) ++ stored
    JSON.send_json(conn, 200, %{threads: threads})
  end

  get "/v1/threads/:thread_id" do
    case safe_get_state(thread_id) do
      {:ok, state} ->
        JSON.send_json(conn, 200, %{thread_id: thread_id, state: sanitize_state(state)})

      :not_found ->
        case store_get_thread(thread_id) do
          {:ok, %Thread{} = t} ->
            JSON.send_json(conn, 200, %{thread_id: thread_id, state: sanitize_thread_record(t)})

          {:error, :not_found} ->
            JSON.send_error(conn, 404, "thread not found")
        end
    end
  end

  get "/v1/threads/:thread_id/history" do
    conn = fetch_query_params(conn)
    offset = parse_int(conn.query_params["offset"], 0)
    limit = parse_int(conn.query_params["limit"], 5000)
    redact? = parse_bool(conn.query_params["redact"] || "1")

    case safe_get_history(thread_id, offset: offset, limit: limit) do
      {:ok, %{items: items} = resp} ->
        items = maybe_redact_history(items, redact?)
        JSON.send_json(conn, 200, Map.put(resp, :items, items) |> Map.put(:thread_id, thread_id))

      {:error, :not_found} ->
        case store_get_history(thread_id, offset, limit) do
          {:ok, %{items: items} = resp} ->
            items = maybe_redact_history(items, redact?)

            JSON.send_json(
              conn,
              200,
              Map.put(resp, :items, items) |> Map.put(:thread_id, thread_id)
            )

          {:error, :not_found} ->
            JSON.send_error(conn, 404, "thread not found")
        end
    end
  end

  get "/v1/threads/:thread_id/messages" do
    conn = fetch_query_params(conn)
    limit = parse_int(conn.query_params["limit"], 50)

    case safe_list_messages(thread_id, limit: limit) do
      {:ok, messages} ->
        JSON.send_json(conn, 200, %{
          thread_id: thread_id,
          messages: sanitize_message_list(messages)
        })

      {:error, :not_found} ->
        case store_list_messages(thread_id, limit) do
          {:ok, messages} ->
            JSON.send_json(conn, 200, %{
              thread_id: thread_id,
              messages: sanitize_message_list(messages)
            })

          {:error, :not_found} ->
            JSON.send_error(conn, 404, "thread not found")
        end
    end
  end

  get "/v1/threads/:thread_id/messages/:message_id" do
    conn = fetch_query_params(conn)
    include_items? = parse_bool(conn.query_params["include_items"] || "0")
    redact? = parse_bool(conn.query_params["redact"] || "1")

    with :ok <- validate_id_optional("message_id", message_id),
         {:ok, message} <- safe_get_message(thread_id, message_id) do
      if include_items? do
        case safe_get_message_items(thread_id, message_id) do
          {:ok, %{items: items}} ->
            items = maybe_redact_history(items, redact?)

            JSON.send_json(conn, 200, %{
              thread_id: thread_id,
              message: sanitize_message(message),
              items: items
            })

          {:error, :thread_not_found} ->
            JSON.send_error(conn, 404, "thread not found")

          {:error, :not_found} ->
            JSON.send_error(conn, 404, "message not found")
        end
      else
        JSON.send_json(conn, 200, %{thread_id: thread_id, message: sanitize_message(message)})
      end
    else
      {:error, :thread_not_found} ->
        case store_get_message(thread_id, message_id, include_items?: include_items?) do
          {:ok, %{message: message, items: items}} ->
            items = maybe_redact_history(items, redact?)

            JSON.send_json(conn, 200, %{
              thread_id: thread_id,
              message: sanitize_message(message),
              items: items
            })

          {:ok, %{message: message}} ->
            JSON.send_json(conn, 200, %{thread_id: thread_id, message: sanitize_message(message)})

          {:error, :thread_not_found} ->
            JSON.send_error(conn, 404, "thread not found")

          {:error, :not_found} ->
            JSON.send_error(conn, 404, "message not found")
        end

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "message not found")

      {:error, {:invalid_id, field, detail}} ->
        JSON.send_error(conn, 400, "invalid #{field}", %{details: detail})
    end
  end

  patch "/v1/threads/:thread_id" do
    params = conn.body_params || %{}
    config = Map.get(params, "config", params)

    case safe_get_state(thread_id) do
      {:ok, _} ->
        :ok = EchsCore.configure_thread(thread_id, normalize_config(config))
        JSON.send_json(conn, 200, %{ok: true})

      :not_found ->
        case EchsCore.restore_thread(thread_id) do
          {:ok, _} ->
            :ok = EchsCore.configure_thread(thread_id, normalize_config(config))
            JSON.send_json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            JSON.send_error(conn, 404, "thread not found")

          {:error, reason} ->
            JSON.send_error(conn, 500, "restore failed", %{reason: inspect(reason)})
        end
    end
  end

  post "/v1/threads/:thread_id/messages" do
    params = conn.body_params || %{}

    mode = params["mode"] || "queue"
    configure = normalize_config(params["configure"] || %{})
    message_id = params["message_id"]

    with :ok <- validate_id_optional("message_id", message_id),
         {:ok, content} <- extract_and_normalize_content(params) do
      _ = EchsServer.ThreadEventBuffer.ensure_started(thread_id)

      opts =
        []
        |> Keyword.put(:mode, mode)
        |> Keyword.put(:configure, configure)
        |> maybe_put_kw(:message_id, message_id)

      case safe_enqueue_message(thread_id, content, opts) do
        {:ok, message_id} ->
          JSON.send_json(conn, 202, %{ok: true, thread_id: thread_id, message_id: message_id})

        {:error, :not_found} ->
          case EchsCore.restore_thread(thread_id) do
            {:ok, _} ->
              case safe_enqueue_message(thread_id, content, opts) do
                {:ok, message_id} ->
                  JSON.send_json(conn, 202, %{
                    ok: true,
                    thread_id: thread_id,
                    message_id: message_id
                  })

                {:error, :paused} ->
                  JSON.send_error(conn, 409, "thread is paused")

                {:error, :not_found} ->
                  JSON.send_error(conn, 404, "thread not found")

                {:error, reason} ->
                  JSON.send_error(conn, 500, "enqueue_message failed", %{reason: inspect(reason)})
              end

            {:error, :not_found} ->
              JSON.send_error(conn, 404, "thread not found")

            {:error, reason} ->
              JSON.send_error(conn, 500, "restore failed", %{reason: inspect(reason)})
          end

        {:error, :paused} ->
          JSON.send_error(conn, 409, "thread is paused")

        {:error, reason} ->
          JSON.send_error(conn, 500, "enqueue_message failed", %{reason: inspect(reason)})
      end
    else
      {:error, {:invalid_id, field, detail}} ->
        JSON.send_error(conn, 400, "invalid #{field}", %{details: detail})

      {:error, {:invalid_content, reason}} ->
        JSON.send_error(conn, 400, "invalid content", %{reason: inspect(reason)})
    end
  end

  post "/v1/threads/:thread_id/interrupt" do
    case safe_interrupt(thread_id) do
      :ok ->
        JSON.send_json(conn, 200, %{ok: true})

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "thread not found")

      {:error, reason} ->
        JSON.send_error(conn, 500, "interrupt failed", %{reason: inspect(reason)})
    end
  end

  post "/v1/threads/:thread_id/pause" do
    case safe_pause(thread_id) do
      :ok -> JSON.send_json(conn, 200, %{ok: true})
      {:error, :not_found} -> JSON.send_error(conn, 404, "thread not found")
      {:error, reason} -> JSON.send_error(conn, 500, "pause failed", %{reason: inspect(reason)})
    end
  end

  post "/v1/threads/:thread_id/resume" do
    case safe_resume(thread_id) do
      :ok -> JSON.send_json(conn, 200, %{ok: true})
      {:error, :not_found} -> JSON.send_error(conn, 404, "thread not found")
      {:error, reason} -> JSON.send_error(conn, 500, "resume failed", %{reason: inspect(reason)})
    end
  end

  delete "/v1/threads/:thread_id" do
    case safe_kill(thread_id) do
      :ok -> JSON.send_json(conn, 200, %{ok: true})
      {:error, :not_found} -> JSON.send_error(conn, 404, "thread not found")
      {:error, reason} -> JSON.send_error(conn, 500, "kill failed", %{reason: inspect(reason)})
    end
  end

  # --- SSE event stream (thread events)

  get "/v1/threads/:thread_id/events" do
    case safe_get_state(thread_id) do
      {:ok, _state} ->
        last_event_id =
          conn
          |> get_req_header("last-event-id")
          |> List.first()
          |> parse_int(nil)

        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(200)
        |> stream_thread_events(thread_id, last_event_id)

      :not_found ->
        JSON.send_error(conn, 404, "thread not found")
    end
  end

  match _ do
    JSON.send_error(conn, 404, "not found")
  end

  # --- Streaming

  defp stream_thread_events(conn, thread_id, last_event_id) do
    :ok = EchsServer.ThreadEventBuffer.subscribe(thread_id, last_event_id)

    case chunk(conn, sse_event("ready", %{thread_id: thread_id})) do
      {:ok, conn} -> stream_loop(conn)
      {:error, _} -> conn
    end
  end

  defp stream_conversation_events(conn, conversation_id, last_event_id) do
    :ok = EchsServer.ConversationEventBuffer.subscribe(conversation_id, last_event_id)

    case chunk(conn, sse_event("ready", %{conversation_id: conversation_id})) do
      {:ok, conn} -> stream_loop(conn)
      {:error, _} -> conn
    end
  end

  defp stream_loop(conn) do
    receive do
      {:event, id, event_type, data} ->
        payload = sse_event(to_string(event_type), data, id)

        case chunk(conn, payload) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    after
      15_000 ->
        # Keepalive to prevent some proxies from closing idle streams.
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp sse_event(event, data, id \\ nil) do
    json =
      case Jason.encode(data) do
        {:ok, encoded} ->
          encoded

        {:error, _reason} ->
          # Fallback: convert to inspected string if data can't be encoded
          # This prevents crashes when error tuples leak into event data
          Jason.encode!(%{
            error: "encoding_failed",
            inspected: inspect(data, limit: 500, printable_limit: 1000)
          })
      end

    id_line =
      case id do
        nil -> ""
        _ -> "id: #{id}\n"
      end

    id_line <> "event: #{event}\n" <> "data: #{json}\n\n"
  end

  # --- Normalization / safety

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, _key, ""), do: opts

  defp maybe_put_kw(opts, key, value) do
    Keyword.put(opts, key, value)
  end

  defp maybe_put_config(config, _key, nil), do: config
  defp maybe_put_config(config, _key, ""), do: config

  defp maybe_put_config(config, key, value) do
    Map.put(config, key, value)
  end

  defp parse_coordination(nil), do: nil
  defp parse_coordination("hierarchical"), do: :hierarchical
  defp parse_coordination("blackboard"), do: :blackboard
  defp parse_coordination("peer"), do: :peer
  defp parse_coordination(_), do: nil

  defp normalize_config(config) when is_map(config), do: stringify_keys(config)
  defp normalize_config(_), do: %{}

  defp stringify_keys(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), v)
    end)
  end

  defp parse_bool(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp parse_bool(_), do: false

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_other, default), do: default

  defp validate_id_optional(_field, nil), do: :ok
  defp validate_id_optional(_field, ""), do: :ok

  defp validate_id_optional(field, value) when is_binary(value) do
    cond do
      byte_size(value) > 256 ->
        {:error, {:invalid_id, field, %{reason: "too long", max_bytes: 256}}}

      true ->
        :ok
    end
  end

  defp validate_id_optional(field, other) do
    {:error, {:invalid_id, field, %{reason: "expected string", got: inspect(other)}}}
  end

  defp extract_and_normalize_content(params) when is_map(params) do
    content =
      cond do
        is_binary(params["content"]) ->
          params["content"]

        is_list(params["content"]) ->
          params["content"]

        is_map(params["content"]) ->
          [params["content"]]

        is_binary(params["text"]) ->
          params["text"]

        true ->
          ""
      end

    case content do
      items when is_list(items) ->
        items =
          Enum.map(items, fn item -> if is_map(item), do: stringify_keys(item), else: item end)

        case MessageContent.normalize(items) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, {:invalid_content, reason}}
        end

      other ->
        {:ok, other}
    end
  end

  defp safe_get_state(thread_id) do
    try do
      {:ok, EchsCore.get_state(thread_id)}
    catch
      :exit, _ -> :not_found
    end
  end

  defp store_enabled? do
    Code.ensure_loaded?(EchsStore) and EchsStore.enabled?()
  end

  defp store_get_thread(thread_id) do
    if store_enabled?() do
      EchsStore.get_thread(thread_id)
    else
      {:error, :not_found}
    end
  end

  defp store_get_history(thread_id, offset, limit) do
    if store_enabled?() do
      EchsStore.get_slice(thread_id, offset, limit)
    else
      {:error, :not_found}
    end
  end

  defp store_list_messages(thread_id, limit) do
    if store_enabled?() do
      case EchsStore.get_thread(thread_id) do
        {:ok, _} ->
          messages =
            EchsStore.list_messages(thread_id, limit: limit)
            |> Enum.map(&store_message_to_meta/1)

          {:ok, messages}

        {:error, :not_found} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp store_get_message(thread_id, message_id, opts) do
    include_items? = Keyword.get(opts, :include_items?, false)

    if store_enabled?() do
      with {:ok, _} <- EchsStore.get_thread(thread_id),
           {:ok, %Message{} = msg} <- EchsStore.get_message(thread_id, message_id) do
        meta = store_message_to_meta(msg)

        if include_items? do
          case EchsStore.get_by_message(thread_id, message_id) do
            {:ok, items} -> {:ok, %{message: meta, items: items}}
            {:error, :not_found} -> {:ok, %{message: meta, items: []}}
          end
        else
          {:ok, %{message: meta}}
        end
      else
        {:error, :not_found} ->
          # Could be missing thread or missing message; check thread first to
          # make the response stable.
          case EchsStore.get_thread(thread_id) do
            {:ok, _} -> {:error, :not_found}
            {:error, :not_found} -> {:error, :thread_not_found}
          end
      end
    else
      {:error, :thread_not_found}
    end
  end

  defp safe_get_history(thread_id, opts) do
    try do
      EchsCore.get_history(thread_id, opts)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp safe_list_messages(thread_id, opts) do
    try do
      {:ok, EchsCore.list_messages(thread_id, opts)}
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp safe_get_message(thread_id, message_id) do
    try do
      EchsCore.get_message(thread_id, message_id)
    catch
      :exit, _ -> {:error, :thread_not_found}
    end
  end

  defp safe_get_message_items(thread_id, message_id) do
    try do
      EchsCore.get_message_items(thread_id, message_id)
    catch
      :exit, _ -> {:error, :thread_not_found}
    end
  end

  defp safe_enqueue_message(thread_id, content, opts) do
    try do
      EchsCore.enqueue_message(thread_id, content, opts)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp safe_interrupt(thread_id) do
    try do
      :ok = EchsCore.interrupt_thread(thread_id)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp safe_pause(thread_id) do
    try do
      :ok = EchsCore.pause_thread(thread_id)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp safe_resume(thread_id) do
    try do
      :ok = EchsCore.resume_thread(thread_id)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp safe_kill(thread_id) do
    try do
      :ok = EchsCore.kill_thread(thread_id)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp sanitize_message_list(messages) when is_list(messages) do
    Enum.map(messages, &sanitize_message/1)
  end

  defp sanitize_message(meta) when is_map(meta) do
    %{
      message_id: meta.message_id,
      status: to_string(meta.status),
      enqueued_at: iso8601(meta.enqueued_at_ms),
      started_at: iso8601(meta.started_at_ms),
      completed_at: iso8601(meta.completed_at_ms),
      history_start: meta.history_start,
      history_end: meta.history_end,
      error: format_message_error(meta.error)
    }
  end

  defp format_message_error(nil), do: nil
  defp format_message_error(err) when is_binary(err), do: err
  defp format_message_error(err), do: inspect(err)

  defp store_message_to_meta(%Message{} = msg) do
    %{
      message_id: msg.message_id,
      status: msg.status,
      enqueued_at_ms: msg.enqueued_at_ms,
      started_at_ms: msg.started_at_ms,
      completed_at_ms: msg.completed_at_ms,
      history_start: msg.history_start,
      history_end: msg.history_end,
      error: msg.error
    }
  end

  defp maybe_redact_history(items, false), do: items

  defp maybe_redact_history(items, true) when is_list(items) do
    Enum.map(items, &redact_history_item/1)
  end

  defp redact_history_item(item) when is_map(item) do
    case item["type"] do
      "message" ->
        Map.update(item, "content", [], fn content ->
          Enum.map(content, &redact_content_item/1)
        end)

      _ ->
        item
    end
  end

  defp redact_history_item(other), do: other

  defp redact_content_item(%{"type" => "input_image", "image_url" => url} = item)
       when is_binary(url) and url != "" do
    if String.starts_with?(url, "data:") do
      Map.put(item, "image_url", redact_data_url(url))
    else
      item
    end
  end

  defp redact_content_item(item), do: item

  defp redact_data_url(url) do
    case String.split(url, ",", parts: 2) do
      [prefix, _] -> prefix <> ",[redacted]"
      _ -> "data:[redacted]"
    end
  end

  defp sanitize_state(state) do
    # The full internal state includes tool handlers and other runtime refs;
    # keep the wire response stable and JSON-friendly.
    %{
      thread_id: state.thread_id,
      parent_thread_id: state.parent_thread_id,
      created_at: iso8601(state.created_at_ms),
      last_activity_at: iso8601(state.last_activity_at_ms),
      model: state.model,
      reasoning: state.reasoning,
      cwd: state.cwd,
      status: state.status,
      current_message_id: state.current_message_id,
      trace_id: state.trace_id,
      current_turn_started_at: iso8601(state.current_turn_started_at_ms),
      queued_turns: length(state.queued_turns),
      steer_queue: length(state.steer_queue),
      history_items: length(state.history_items),
      coordination_mode: state.coordination_mode,
      tools: Enum.map(state.tools, fn t -> Map.get(t, "name") || Map.get(t, "type") end),
      children: Map.keys(state.children)
    }
  end

  defp sanitize_thread_record(%Thread{} = t) do
    tools =
      case Jason.decode(t.tools_json || "[]") do
        {:ok, list} when is_list(list) ->
          list
          |> Enum.map(fn
            tool when is_map(tool) -> Map.get(tool, "name") || Map.get(tool, "type")
            tool when is_binary(tool) -> tool
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    %{
      thread_id: t.thread_id,
      conversation_id: Map.get(t, :conversation_id),
      parent_thread_id: t.parent_thread_id,
      created_at: iso8601(t.created_at_ms),
      last_activity_at: iso8601(t.last_activity_at_ms),
      model: t.model,
      reasoning: t.reasoning,
      cwd: t.cwd,
      status: "stored",
      current_message_id: nil,
      current_turn_started_at: nil,
      queued_turns: nil,
      steer_queue: nil,
      history_items: t.history_count || 0,
      coordination_mode: t.coordination_mode,
      tools: tools,
      children: []
    }
  end

  defp sanitize_conversation_record(%Conversation{} = c) do
    tools =
      case Jason.decode(c.tools_json || "[]") do
        {:ok, list} when is_list(list) ->
          list
          |> Enum.map(fn
            tool when is_map(tool) -> Map.get(tool, "name") || Map.get(tool, "type")
            tool when is_binary(tool) -> tool
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    %{
      conversation_id: c.conversation_id,
      active_thread_id: c.active_thread_id,
      created_at: iso8601(c.created_at_ms),
      last_activity_at: iso8601(c.last_activity_at_ms),
      model: c.model,
      reasoning: c.reasoning,
      cwd: c.cwd,
      instructions: c.instructions,
      coordination_mode: c.coordination_mode,
      tools: tools
    }
  end

  defp iso8601(nil), do: nil

  defp iso8601(ms) when is_integer(ms) and ms >= 0 do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
