defmodule EchsServer.AuthPlug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case EchsServer.api_token() do
      nil ->
        conn

      token ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> provided] when provided == token ->
            conn

          _ ->
            conn
            |> EchsServer.JSON.send_error(401, "unauthorized")
            |> halt()
        end
    end
  end
end
