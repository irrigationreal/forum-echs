defmodule EchsServer.Uploads do
  @moduledoc false

  @max_bytes 5_000_000

  @spec prepare_image(Plug.Upload.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_image(%Plug.Upload{} = upload, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(upload.path),
         :ok <- check_size(size, max_bytes),
         {:ok, bytes} <- File.read(upload.path),
         {:ok, mime} <- image_mime(upload) do
      encoded = Base.encode64(bytes)
      image_url = "data:#{mime};base64,#{encoded}"

      {:ok,
       %{
         upload_id: generate_upload_id(),
         kind: "image",
         bytes: size,
         filename: upload.filename,
         content_type: mime,
         image_url: image_url,
         # Convenience: ready-to-inline Responses-style content item.
         content: %{"type" => "input_image", "image_url" => image_url}
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

  defp image_mime(%Plug.Upload{} = upload) do
    content_type = upload.content_type || ""
    guessed = guess_mime(upload.filename || "")

    cond do
      String.starts_with?(content_type, "image/") ->
        {:ok, content_type}

      String.starts_with?(guessed, "image/") ->
        {:ok, guessed}

      content_type != "" ->
        {:error, {:unsupported_content_type, content_type}}

      true ->
        {:error, {:unsupported_content_type, guessed}}
    end
  end

  defp guess_mime(filename) do
    case Path.extname(filename) |> String.downcase() do
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

  defp generate_upload_id do
    "upl_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end

