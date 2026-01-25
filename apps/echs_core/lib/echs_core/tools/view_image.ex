defmodule EchsCore.Tools.ViewImage do
  @moduledoc """
  Tool for attaching a local image file to the conversation context.

  This mirrors how upstream Codex handles local image attachments: read the file
  from disk and embed it as a base64 `data:` URL inside an `input_image` content
  item.
  """

  @max_bytes 5_000_000

  def spec do
    %{
      "type" => "function",
      "name" => "view_image",
      "description" =>
        "Attach a local image (by filesystem path) to the conversation context for this turn.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Local filesystem path to an image file"
          }
        },
        "required" => ["path"],
        "additionalProperties" => false
      }
    }
  end

  @doc """
  Build a Responses-style `message` item with `input_image` content.

  Options:
    - `:cwd` - base directory for resolving relative paths
    - `:max_bytes` - max bytes to read (defaults to #{@max_bytes})
  """
  @spec build_message_item(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_message_item(path, opts \\ []) when is_binary(path) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    abs_path = Path.expand(path, cwd)

    with {:ok, meta} <- EchsCore.Uploads.store_file(abs_path, max_bytes: max_bytes) do
      {:ok,
       %{
         "type" => "message",
         "role" => "user",
         # Store an upload handle in history and expand to `image_url` only when
         # building the API payload. This keeps persisted history small.
         "content" => [%{"type" => "input_image", "upload_id" => meta.upload_id}]
       }}
    end
  end
end
