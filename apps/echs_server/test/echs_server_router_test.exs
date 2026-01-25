defmodule EchsServer.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias EchsServer.Router

  setup do
    {:ok, _} = Application.ensure_all_started(:echs_core)
    {:ok, _} = Application.ensure_all_started(:echs_codex)
    :ok
  end

  test "healthz" do
    conn = conn(:get, "/healthz")
    conn = Router.call(conn, [])
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["ok"] == true
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
