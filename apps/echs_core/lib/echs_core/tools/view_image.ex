defmodule EchsCore.Tools.ViewImage do
  @moduledoc """
  Tool for attaching a local image file to the conversation context.

  This mirrors how upstream Codex handles local image attachments: read the file
  from disk and embed it as a base64 `data:` URL inside an `input_image` content
  item.
  """

  @max_width 2048
  @max_height 768

  def spec do
    %{
      "type" => "function",
      "name" => "view_image",
      "description" =>
        "View a local image from the filesystem (only use if given a full filepath by the user, and the image isn't already attached to the thread context within <image ...> tags).",
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
  """
  @spec build_message_item(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_message_item(path, opts \\ []) when is_binary(path) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    abs_path = Path.expand(path, cwd)

    case File.stat(abs_path) do
      {:ok, %File.Stat{type: :regular}} ->
        content_item = build_content_item(abs_path)

        {:ok,
         %{
           "type" => "message",
           "role" => "user",
           "content" => [content_item]
         }}

      {:ok, %File.Stat{type: _other}} ->
        {:error, "image path `#{abs_path}` is not a file"}

      {:error, reason} ->
        {:error, "unable to locate image at `#{abs_path}`: #{:file.format_error(reason)}"}
    end
  end

  defp build_content_item(path) do
    case process_image(path) do
      {:ok, mime, data} ->
        %{"type" => "input_image", "image_url" => "data:#{mime};base64,#{Base.encode64(data)}"}

      {:error, {:invalid, reason}} ->
        %{
          "type" => "input_text",
          "text" => "Image located at `#{path}` is invalid: #{reason}"
        }

      {:error, {:unsupported, mime}} ->
        %{
          "type" => "input_text",
          "text" => "Codex cannot attach image at `#{path}`: unsupported image format `#{mime}`."
        }

      {:error, {:unsupported_mime, mime}} ->
        %{
          "type" => "input_text",
          "text" => "Codex could not read the local image at `#{path}`: unsupported MIME type `#{mime}`"
        }

      {:error, :unknown_mime} ->
        %{
          "type" => "input_text",
          "text" => "Codex could not read the local image at `#{path}`: unsupported MIME type (unknown)"
        }

      {:error, {:read, reason}} ->
        %{
          "type" => "input_text",
          "text" => "Codex could not read the local image at `#{path}`: #{reason}"
        }
    end
  end

  defp process_image(path) do
    mime_guess = guess_mime(path)

    case run_python_image(path) do
      {:ok, %{mime: mime, data: data}} ->
        {:ok, mime, data}

      {:error, {:invalid, reason}} ->
        {:error, {:invalid, "failed to decode image at #{path}: #{reason}"}}

      {:error, {:encode, _reason}} ->
        case mime_guess do
          nil -> {:error, :unknown_mime}
          mime ->
            if String.starts_with?(mime, "image/") do
              {:error, {:unsupported, mime}}
            else
              {:error, {:unsupported_mime, mime}}
            end
        end

      {:error, {:read, reason}} ->
        {:error, {:read, "failed to read image at #{path}: #{reason}"}}
    end
  end

  defp run_python_image(path) do
    script = """
import base64
import json
import sys
from io import BytesIO

try:
    from PIL import Image, UnidentifiedImageError
except Exception as e:
    print(json.dumps({"ok": False, "error_type": "encode", "message": str(e)}))
    sys.exit(0)

MAX_WIDTH = #{@max_width}
MAX_HEIGHT = #{@max_height}

try:
    with open(sys.argv[1], "rb") as f:
        original = f.read()

    try:
        img = Image.open(sys.argv[1])
        img.load()
    except UnidentifiedImageError as e:
        print(json.dumps({"ok": False, "error_type": "invalid", "message": str(e)}))
        sys.exit(0)
    except Exception as e:
        print(json.dumps({"ok": False, "error_type": "invalid", "message": str(e)}))
        sys.exit(0)

    fmt = (img.format or "").upper()
    width, height = img.size

    if fmt in ("PNG", "JPEG") and width <= MAX_WIDTH and height <= MAX_HEIGHT:
        mime = "image/png" if fmt == "PNG" else "image/jpeg"
        data = original
    else:
        if width > MAX_WIDTH or height > MAX_HEIGHT:
            resampling = getattr(Image, "Resampling", Image)
            img.thumbnail((MAX_WIDTH, MAX_HEIGHT), resampling.BILINEAR)

        target = fmt if fmt in ("PNG", "JPEG") else "PNG"
        out = BytesIO()
        if target == "JPEG":
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            img.save(out, format="JPEG", quality=85)
            mime = "image/jpeg"
        else:
            img.save(out, format="PNG")
            mime = "image/png"
        data = out.getvalue()

    print(json.dumps({"ok": True, "mime": mime, "data": base64.b64encode(data).decode("ascii")}))
except Exception as e:
    print(json.dumps({"ok": False, "error_type": "encode", "message": str(e)}))
"""

    case System.cmd("python3", ["-c", script, path], stderr_to_stdout: true) do
      {output, 0} ->
        parse_python_output(output)

      {output, _} ->
        {:error, {:read, String.trim_trailing(output)}}
    end
  rescue
    e ->
      {:error, {:read, Exception.message(e)}}
  end

  defp parse_python_output(output) do
    with {:ok, data} <- Jason.decode(output),
         true <- is_map(data) do
      case data do
        %{"ok" => true, "mime" => mime, "data" => encoded} when is_binary(mime) ->
          case Base.decode64(encoded) do
            {:ok, bytes} -> {:ok, %{mime: mime, data: bytes}}
            :error -> {:error, {:encode, "invalid base64 output"}}
          end

        %{"ok" => false, "error_type" => "invalid", "message" => message} ->
          {:error, {:invalid, message}}

        %{"ok" => false, "error_type" => "encode", "message" => message} ->
          {:error, {:encode, message}}

        %{"ok" => false, "error_type" => "read", "message" => message} ->
          {:error, {:read, message}}

        _ ->
          {:error, {:encode, "unexpected image processing response"}}
      end
    else
      _ -> {:error, {:encode, String.trim_trailing(output)}}
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
      _ -> nil
    end
  end
end
