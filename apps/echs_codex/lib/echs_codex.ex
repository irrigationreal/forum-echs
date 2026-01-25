defmodule EchsCodex do
  @moduledoc """
  Codex API client for hitting the responses endpoint.
  Handles auth, SSE streaming, and compaction.
  """

  alias EchsCodex.{Auth, Responses}

  defdelegate load_auth(path), to: Auth
  defdelegate refresh_auth(), to: Auth

  defdelegate stream_response(opts), to: Responses
  defdelegate compact(opts), to: Responses
end
