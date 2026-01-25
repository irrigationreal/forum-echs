defmodule EchsServer.JSON do
  @moduledoc false

  import Plug.Conn

  def send_json(conn, status, data) do
    body = Jason.encode!(data)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  def send_error(conn, status, message, extra \\ %{}) do
    send_json(conn, status, Map.merge(%{error: message}, extra))
  end
end
