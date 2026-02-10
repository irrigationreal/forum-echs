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
          ["Bearer " <> provided] ->
            provided = String.trim(provided)

            if secure_compare(provided, token) do
              conn
            else
              conn
              |> EchsServer.JSON.send_error(401, "unauthorized")
              |> halt()
            end

          _ ->
            conn
            |> EchsServer.JSON.send_error(401, "unauthorized")
            |> halt()
        end
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    # `Plug.Crypto.secure_compare/2` requires equal length.
    if byte_size(a) == byte_size(b) do
      Plug.Crypto.secure_compare(a, b)
    else
      false
    end
  end

  defp secure_compare(_, _), do: false
end
