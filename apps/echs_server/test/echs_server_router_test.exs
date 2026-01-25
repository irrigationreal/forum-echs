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
end
