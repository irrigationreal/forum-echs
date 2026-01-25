defmodule EchsServer.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias EchsServer.Router

  setup do
    {:ok, _} = Application.ensure_all_started(:echs_core)
    {:ok, _} = Application.ensure_all_started(:echs_codex)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "echs_uploads_test_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    System.put_env("ECHS_UPLOAD_DIR", tmp)

    on_exit(fn ->
      System.delete_env("ECHS_UPLOAD_DIR")
      File.rm_rf(tmp)
    end)

    :ok
  end

  test "healthz" do
    conn = conn(:get, "/healthz")
    conn = Router.call(conn, [])
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["ok"] == true
  end

  test "openapi.json" do
    conn = conn(:get, "/openapi.json")
    conn = Router.call(conn, [])
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["openapi"] == "3.1.0"
    assert get_in(body, ["paths", "/v1/threads"])
  end

  test "uploads accepts multipart image (handle mode by default)" do
    boundary = "----echs-test-boundary"
    bytes = "not really a png"

    body =
      [
        "--",
        boundary,
        "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n",
        "Content-Type: image/png\r\n\r\n",
        bytes,
        "\r\n--",
        boundary,
        "--\r\n"
      ]
      |> IO.iodata_to_binary()

    conn =
      conn(:post, "/v1/uploads", body)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")

    conn = Router.call(conn, [])
    assert conn.status == 201

    resp = Jason.decode!(conn.resp_body)
    assert resp["kind"] == "image"
    assert resp["upload_id"]
    assert resp["image_url"] == nil
    assert resp["content"]["type"] == "input_image"
    assert resp["content"]["upload_id"] == resp["upload_id"]
  end

  test "uploads can inline as data url" do
    boundary = "----echs-test-boundary"
    bytes = "not really a png"

    body =
      [
        "--",
        boundary,
        "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n",
        "Content-Type: image/png\r\n\r\n",
        bytes,
        "\r\n--",
        boundary,
        "--\r\n"
      ]
      |> IO.iodata_to_binary()

    conn =
      conn(:post, "/v1/uploads?inline=1", body)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")

    conn = Router.call(conn, [])
    assert conn.status == 201

    resp = Jason.decode!(conn.resp_body)
    assert resp["kind"] == "image"
    assert String.starts_with?(resp["image_url"], "data:image/png;base64,")
    assert resp["content"]["type"] == "input_image"
    assert String.starts_with?(resp["content"]["image_url"], "data:image/png;base64,")
  end

  test "create thread and fetch state" do
    body = Jason.encode!(%{"cwd" => File.cwd!()})

    conn =
      conn(:post, "/v1/threads", body)
      |> put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])
    assert conn.status == 201

    thread_id = Jason.decode!(conn.resp_body)["thread_id"]
    assert is_binary(thread_id)

    conn = conn(:get, "/v1/threads/#{thread_id}")
    conn = Router.call(conn, [])
    assert conn.status == 200

    state = Jason.decode!(conn.resp_body)["state"]
    assert state["thread_id"] == thread_id
  end

  test "history and message endpoints work for an empty thread" do
    body = Jason.encode!(%{"cwd" => File.cwd!()})

    conn =
      conn(:post, "/v1/threads", body)
      |> put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])
    thread_id = Jason.decode!(conn.resp_body)["thread_id"]

    conn = conn(:get, "/v1/threads/#{thread_id}/history")
    conn = Router.call(conn, [])
    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["thread_id"] == thread_id
    assert resp["total"] == 0
    assert resp["items"] == []

    conn = conn(:get, "/v1/threads/#{thread_id}/messages")
    conn = Router.call(conn, [])
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["messages"] == []
  end

  test "message metadata + items can be fetched" do
    body = Jason.encode!(%{"cwd" => File.cwd!()})

    conn =
      conn(:post, "/v1/threads", body)
      |> put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])
    thread_id = Jason.decode!(conn.resp_body)["thread_id"]

    # Inject some message history + message_log without hitting the external Codex API.
    [{pid, _}] = Registry.lookup(EchsCore.Registry, thread_id)

    message_id = "msg_test_1"

    :sys.replace_state(pid, fn state ->
      history_items = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "a"}]
        },
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => "data:image/png;base64,AAAA"}]
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "b"}]
        }
      ]

      meta = %{
        message_id: message_id,
        status: :completed,
        enqueued_at_ms: state.created_at_ms,
        started_at_ms: state.created_at_ms,
        completed_at_ms: state.created_at_ms,
        history_start: 0,
        history_end: length(history_items),
        error: nil
      }

      %{
        state
        | history_items: history_items,
          message_ids: [message_id],
          message_id_set: MapSet.new([message_id]),
          message_log: %{message_id => meta}
      }
    end)

    conn = conn(:get, "/v1/threads/#{thread_id}/messages")
    conn = Router.call(conn, [])
    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert length(resp["messages"]) == 1
    assert hd(resp["messages"])["message_id"] == message_id

    conn = conn(:get, "/v1/threads/#{thread_id}/messages/#{message_id}?include_items=1")
    conn = Router.call(conn, [])
    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["message"]["message_id"] == message_id
    assert length(resp["items"]) == 3

    # Verify base64 data urls are redacted by default.
    img = Enum.at(resp["items"], 1)
    assert img["type"] == "message"
    assert String.contains?(img["content"] |> hd() |> Map.get("image_url"), "[redacted]")
  end

  test "patch updates config" do
    body = Jason.encode!(%{"cwd" => File.cwd!()})

    conn =
      conn(:post, "/v1/threads", body)
      |> put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])
    thread_id = Jason.decode!(conn.resp_body)["thread_id"]

    patch_body = Jason.encode!(%{"config" => %{"reasoning" => "high"}})

    conn =
      conn(:patch, "/v1/threads/#{thread_id}", patch_body)
      |> put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])
    assert conn.status == 200

    conn = conn(:get, "/v1/threads/#{thread_id}")
    conn = Router.call(conn, [])
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["state"]["reasoning"] == "high"
  end

  test "stored thread can be listed and fetched (no live worker)" do
    now = System.system_time(:millisecond)
    thread_id = "thr_store_test_" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _} =
      EchsStore.upsert_thread(%{
        thread_id: thread_id,
        parent_thread_id: nil,
        created_at_ms: now,
        last_activity_at_ms: now,
        model: "gpt-5.2-codex",
        reasoning: "medium",
        cwd: File.cwd!(),
        instructions: "hi",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 0
      })

    # Not running yet.
    assert Registry.lookup(EchsCore.Registry, thread_id) == []

    conn = conn(:get, "/v1/threads")
    conn = Router.call(conn, [])
    assert conn.status == 200

    threads = Jason.decode!(conn.resp_body)["threads"]

    stored =
      Enum.find(threads, fn t ->
        t["thread_id"] == thread_id
      end)

    assert stored["status"] == "stored"

    conn = conn(:get, "/v1/threads/#{thread_id}")
    conn = Router.call(conn, [])
    assert conn.status == 200

    state = Jason.decode!(conn.resp_body)["state"]
    assert state["thread_id"] == thread_id
    assert state["status"] == "stored"
  end

  test "patch restores a stored thread into memory" do
    now = System.system_time(:millisecond)
    thread_id = "thr_restore_test_" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _} =
      EchsStore.upsert_thread(%{
        thread_id: thread_id,
        parent_thread_id: nil,
        created_at_ms: now,
        last_activity_at_ms: now,
        model: "gpt-5.2-codex",
        reasoning: "medium",
        cwd: File.cwd!(),
        instructions: "hi",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 0
      })

    patch_body = Jason.encode!(%{"config" => %{"reasoning" => "high"}})

    conn =
      conn(:patch, "/v1/threads/#{thread_id}", patch_body)
      |> put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])
    assert conn.status == 200

    assert [{pid, _}] = Registry.lookup(EchsCore.Registry, thread_id)
    assert is_pid(pid)
  end
end
