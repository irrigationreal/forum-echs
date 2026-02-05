defmodule EchsCodex.ResponsesRetryTest do
  use ExUnit.Case, async: false

  alias EchsCodex.{Auth, Responses}

  setup :configure_req_test

  setup_all do
    auth_path =
      Path.join(System.tmp_dir!(), "echs_codex_auth_#{System.unique_integer([:positive])}.json")

    token = jwt_with_exp(System.system_time(:second) + 3600)

    json = %{
      "tokens" => %{
        "access_token" => token,
        "refresh_token" => "refresh",
        "id_token" => "id",
        "account_id" => "acct_test"
      }
    }

    File.write!(auth_path, Jason.encode!(json))

    case Process.whereis(Auth) do
      nil ->
        start_supervised!({Auth, auth_path: auth_path})

      _pid ->
        {:ok, auth} = Auth.load_auth(auth_path)
        Agent.update(Auth, fn _state -> %{auth: auth, path: auth_path} end)
    end

    :ok
  end

  defp configure_req_test(context) do
    :ok = Req.Test.set_req_test_from_context(context)
    :ok = Req.Test.verify_on_exit!(context)
    :ok
  end

  test "stream_response retries transient HTTP errors for POST" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "internal")
    end)

    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
    end)

    on_event = fn _event -> :ok end

    assert {:ok, %{status: 200}} =
             Responses.stream_response(
               model: "gpt-5.3-codex",
               instructions: "test",
               input: [],
               tools: [],
               reasoning: "none",
               on_event: on_event,
               req_opts: [
                 plug: {Req.Test, stub},
                 retry_delay: fn _ -> 0 end,
                 max_retries: 1
               ]
             )
  end

  test "stream_response retries once without reasoning summary on 400/403" do
    stub = {__MODULE__, make_ref()}

    previous = System.get_env("ECHS_REASONING_SUMMARY")

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("ECHS_REASONING_SUMMARY")
      else
        System.put_env("ECHS_REASONING_SUMMARY", previous)
      end
    end)

    System.put_env("ECHS_REASONING_SUMMARY", "auto")

    Req.Test.expect(stub, fn conn ->
      assert get_in(conn.body_params, ["reasoning", "summary"]) == "auto"
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    Req.Test.expect(stub, fn conn ->
      reasoning = conn.body_params["reasoning"] || %{}
      assert reasoning["effort"] == "medium"
      assert Map.get(reasoning, "summary") == nil

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
    end)

    on_event = fn _event -> :ok end

    assert {:ok, %{status: 200}} =
             Responses.stream_response(
               model: "gpt-5.3-codex",
               instructions: "test",
               input: [],
               tools: [],
               reasoning: "medium",
               on_event: on_event,
               req_opts: [plug: {Req.Test, stub}]
             )
  end

  test "stream_response retries once without reasoning payload on 400/403" do
    stub = {__MODULE__, make_ref()}

    previous = System.get_env("ECHS_REASONING_SUMMARY")

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("ECHS_REASONING_SUMMARY")
      else
        System.put_env("ECHS_REASONING_SUMMARY", previous)
      end
    end)

    System.put_env("ECHS_REASONING_SUMMARY", "auto")

    Req.Test.expect(stub, fn conn ->
      assert get_in(conn.body_params, ["reasoning", "summary"]) == "auto"
      Plug.Conn.send_resp(conn, 403, "forbidden")
    end)

    Req.Test.expect(stub, fn conn ->
      reasoning = conn.body_params["reasoning"] || %{}
      assert Map.get(reasoning, "summary") == nil
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    Req.Test.expect(stub, fn conn ->
      assert Map.has_key?(conn.body_params, "reasoning") == false

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
    end)

    on_event = fn _event -> :ok end

    assert {:ok, %{status: 200}} =
             Responses.stream_response(
               model: "gpt-5.3-codex",
               instructions: "test",
               input: [],
               tools: [],
               reasoning: "medium",
               on_event: on_event,
               req_opts: [plug: {Req.Test, stub}]
             )
  end

  test "compact retries transient HTTP errors for POST" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "internal")
    end)

    Req.Test.expect(stub, fn conn ->
      Req.Test.json(conn, %{"output" => [%{"type" => "message", "role" => "assistant"}]})
    end)

    assert {:ok, %{output: output}} =
             Responses.compact(
               model: "gpt-5.3-codex",
               instructions: "test",
               input: [%{"type" => "message", "role" => "user", "content" => []}],
               req_opts: [
                 plug: {Req.Test, stub},
                 retry_delay: fn _ -> 0 end,
                 max_retries: 1
               ]
             )

    assert is_list(output)
  end

  test "stream_response captures error response body for non-200 responses" do
    stub = {__MODULE__, make_ref()}

    previous = System.get_env("ECHS_REASONING_SUMMARY")

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("ECHS_REASONING_SUMMARY")
      else
        System.put_env("ECHS_REASONING_SUMMARY", previous)
      end
    end)

    System.put_env("ECHS_REASONING_SUMMARY", "auto")

    Req.Test.expect(stub, fn conn ->
      assert get_in(conn.body_params, ["reasoning", "summary"]) == "auto"

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "bad_request", "detail" => "invalid payload"})
    end)

    Req.Test.expect(stub, fn conn ->
      reasoning = conn.body_params["reasoning"] || %{}
      assert Map.get(reasoning, "summary") == nil

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "bad_request", "detail" => "invalid payload"})
    end)

    Req.Test.expect(stub, fn conn ->
      assert Map.has_key?(conn.body_params, "reasoning") == false

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "bad_request", "detail" => "invalid payload"})
    end)

    on_event = fn _event -> :ok end

    assert {:error, %{status: 400, body: body}} =
             Responses.stream_response(
               model: "gpt-5.3-codex",
               instructions: "test",
               input: [],
               tools: [],
               reasoning: "medium",
               on_event: on_event,
               req_opts: [plug: {Req.Test, stub}]
             )

    assert is_binary(body)
    assert body =~ "bad_request"
  end

  defp jwt_with_exp(exp) do
    payload = Jason.encode!(%{"exp" => exp})
    encoded = Base.url_encode64(payload, padding: false)
    "header.#{encoded}.sig"
  end
end
