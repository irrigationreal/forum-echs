defmodule EchsServer.Uploads do
  @moduledoc false

  @max_bytes 5_000_000
  @default_upload_dir "/tmp/echs_uploads"

  @spec upload_dir() :: String.t()
  def upload_dir do
    System.get_env("ECHS_UPLOAD_DIR") || @default_upload_dir
  end

  @spec prepare_image(Plug.Upload.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_image(%Plug.Upload{} = upload, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    inline? = Keyword.get(opts, :inline, false)

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(upload.path),
         :ok <- check_size(size, max_bytes),
         {:ok, mime} <- image_mime(upload),
         {:ok, upload_id} <- store_upload(upload, mime) do
      base = %{
        upload_id: upload_id,
        kind: "image",
        bytes: size,
        filename: upload.filename,
        content_type: mime
      }

      if inline? do
        with {:ok, image_url} <- image_url(upload_id) do
          {:ok,
           Map.merge(base, %{
             image_url: image_url,
             # Convenience: ready-to-inline Responses-style content item.
             content: %{"type" => "input_image", "image_url" => image_url}
           })}
        end
      else
        {:ok,
         Map.merge(base, %{
           # Lightweight handle form; the server can expand this when enqueuing.
           content: %{"type" => "input_image", "upload_id" => upload_id}
         })}
      end
    else
      {:ok, %File.Stat{type: other}} ->
        {:error, {:not_a_file, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec image_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def image_url(upload_id, opts \\ []) when is_binary(upload_id) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    with {:ok, meta} <- read_meta(upload_id),
         stored_filename when is_binary(stored_filename) <- meta["stored_filename"],
         path <- Path.join(upload_dir(), stored_filename),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         :ok <- check_size(size, max_bytes),
         {:ok, bytes} <- File.read(path) do
      mime = meta["content_type"] || "application/octet-stream"
      encoded = Base.encode64(bytes)
      {:ok, "data:#{mime};base64,#{encoded}"}
    else
      nil ->
        {:error, :not_found}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_upload(%Plug.Upload{} = upload, mime) do
    dir = upload_dir()
    :ok = File.mkdir_p(dir)

    upload_id = generate_upload_id()
    stored_filename = upload_id <> preferred_ext(upload.filename || "", mime)

    dest_path = Path.join(dir, stored_filename)
    meta_path = Path.join(dir, upload_id <> ".json")

    with :ok <- File.cp(upload.path, dest_path),
         :ok <-
           write_meta(meta_path, %{
             upload_id: upload_id,
             stored_filename: stored_filename,
             content_type: mime
           }) do
      {:ok, upload_id}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp write_meta(path, meta) when is_map(meta) do
    json =
      meta
      |> Map.put_new(
        :created_at,
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )
      |> Jason.encode_to_iodata!()

    File.write(path, [json, "\n"])
  end

  defp read_meta(upload_id) do
    dir = upload_dir()
    meta_path = Path.join(dir, upload_id <> ".json")

    with {:ok, body} <- File.read(meta_path),
         {:ok, meta} <- Jason.decode(body) do
      {:ok, meta}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preferred_ext(filename, mime) do
    ext = Path.extname(filename) |> String.downcase()

    cond do
      ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".svg"] ->
        ext

      true ->
        ext_for_mime(mime)
    end
  end

  defp ext_for_mime("image/png"), do: ".png"
  defp ext_for_mime("image/jpeg"), do: ".jpg"
  defp ext_for_mime("image/gif"), do: ".gif"
  defp ext_for_mime("image/webp"), do: ".webp"
  defp ext_for_mime("image/bmp"), do: ".bmp"
  defp ext_for_mime("image/tiff"), do: ".tiff"
  defp ext_for_mime("image/svg+xml"), do: ".svg"
  defp ext_for_mime(_), do: ".bin"

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
