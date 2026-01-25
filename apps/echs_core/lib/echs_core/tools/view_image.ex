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

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(abs_path),
         :ok <- check_size(size, max_bytes),
         {:ok, bytes} <- File.read(abs_path) do
      mime = guess_mime(abs_path)
      encoded = Base.encode64(bytes)

      image_url = "data:#{mime};base64,#{encoded}"

      {:ok,
       %{
         "type" => "message",
         "role" => "user",
         "content" => [%{"type" => "input_image", "image_url" => image_url}]
       }}
    else
      {:ok, %File.Stat{type: other}} ->
        {:error, {:not_a_file, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_size(size, max_bytes) when is_integer(size) and is_integer(max_bytes) do
    if size <= max_bytes do
      :ok
    else
      {:error, {:too_large, size, max_bytes}}
    end
  end

  defp guess_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".bmp" -> "image/bmp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".svg" -> "image/svg+xml"
      _ -> "application/octet-stream"
    end
  end
end
