defmodule EchsServer.Router do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias EchsServer.JSON

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
    JSON.send_json(conn, 200, %{ok: true})
  end

  get "/openapi.json" do
    JSON.send_json(conn, 200, EchsProtocol.V1.OpenAPI.spec())
  end

  # --- Uploads

  post "/v1/uploads" do
    params = conn.body_params || %{}

    case Map.get(params, "file") do
      %Plug.Upload{} = upload ->
        case EchsServer.Uploads.prepare_image(upload) do
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

  post "/v1/threads" do
    params = conn.body_params || %{}
    tools = Map.get(params, "tools")

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
        if tools != nil do
          :ok = EchsCore.configure_thread(thread_id, %{"tools" => tools})
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

    threads =
      ids
      |> Enum.map(fn id ->
        case safe_get_state(id) do
          {:ok, state} -> sanitize_state(state)
          :not_found -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    JSON.send_json(conn, 200, %{threads: threads})
  end

  get "/v1/threads/:thread_id" do
    case safe_get_state(thread_id) do
      {:ok, state} ->
        JSON.send_json(conn, 200, %{thread_id: thread_id, state: sanitize_state(state)})

      :not_found ->
        JSON.send_error(conn, 404, "thread not found")
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
        JSON.send_error(conn, 404, "thread not found")
    end
  end

  post "/v1/threads/:thread_id/messages" do
    params = conn.body_params || %{}

    mode = params["mode"] || "queue"
    configure = normalize_config(params["configure"] || %{})
    message_id = params["message_id"]

    content =
      cond do
        is_binary(params["content"]) ->
          params["content"]

        is_list(params["content"]) ->
          params["content"]

        is_binary(params["text"]) ->
          params["text"]

        true ->
          ""
      end

    opts =
      []
      |> Keyword.put(:mode, mode)
      |> Keyword.put(:configure, configure)
      |> maybe_put_kw(:message_id, message_id)

    case safe_enqueue_message(thread_id, content, opts) do
      {:ok, message_id} ->
        JSON.send_json(conn, 202, %{ok: true, thread_id: thread_id, message_id: message_id})

      {:error, :not_found} ->
        JSON.send_error(conn, 404, "thread not found")

      {:error, :paused} ->
        JSON.send_error(conn, 409, "thread is paused")

      {:error, reason} ->
        JSON.send_error(conn, 500, "enqueue_message failed", %{reason: inspect(reason)})
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
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(200)
        |> stream_thread_events(thread_id)

      :not_found ->
        JSON.send_error(conn, 404, "thread not found")
    end
  end

  match _ do
    JSON.send_error(conn, 404, "not found")
  end

  # --- Streaming

  defp stream_thread_events(conn, thread_id) do
    :ok = EchsCore.subscribe(thread_id)

    case chunk(conn, sse_event("ready", %{thread_id: thread_id})) do
      {:ok, conn} -> stream_loop(conn)
      {:error, _} -> conn
    end
  end

  defp stream_loop(conn) do
    receive do
      {event_type, data} ->
        payload = sse_event(to_string(event_type), data)

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

  defp sse_event(event, data) do
    json = Jason.encode!(data)
    "event: #{event}\n" <> "data: #{json}\n\n"
  end

  # --- Normalization / safety

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, _key, ""), do: opts

  defp maybe_put_kw(opts, key, value) do
    Keyword.put(opts, key, value)
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

  defp safe_get_state(thread_id) do
    try do
      {:ok, EchsCore.get_state(thread_id)}
    catch
      :exit, _ -> :not_found
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
      current_turn_started_at: iso8601(state.current_turn_started_at_ms),
      queued_turns: length(state.queued_turns),
      steer_queue: length(state.steer_queue),
      history_items: length(state.history_items),
      coordination_mode: state.coordination_mode,
      tools: Enum.map(state.tools, fn t -> Map.get(t, "name") || Map.get(t, "type") end),
      children: Map.keys(state.children)
    }
  end

  defp iso8601(nil), do: nil

  defp iso8601(ms) when is_integer(ms) and ms >= 0 do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
