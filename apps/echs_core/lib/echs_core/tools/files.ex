defmodule EchsCore.Tools.Files do
  @moduledoc """
  File operation tools: read_file, list_dir, grep_files.
  """

  def read_file_spec do
    %{
      "type" => "function",
      "name" => "read_file",
      "description" => "Read contents of a file",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to read"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start from (0-based)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Number of lines to read"
          }
        },
        "required" => ["file_path"]
      }
    }
  end

  def list_dir_spec do
    %{
      "type" => "function",
      "name" => "list_dir",
      "description" => "List directory contents",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" => "Path to the directory"
          },
          "depth" => %{
            "type" => "integer",
            "description" => "Maximum depth to recurse (default: 1)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of entries (default: 100)"
          }
        },
        "required" => ["dir_path"]
      }
    }
  end

  def grep_files_spec do
    %{
      "type" => "function",
      "name" => "grep_files",
      "description" => "Search for a pattern in files",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regex pattern to search for"
          },
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Paths to search in"
          },
          "include" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Glob patterns to include"
          },
          "exclude" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Glob patterns to exclude"
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Case sensitive search (default: true)"
          }
        },
        "required" => ["pattern", "paths"]
      }
    }
  end

  def read_file(path, opts \\ %{}) do
    offset = get_opt(opts, :offset, 0)
    limit = get_opt(opts, :limit, nil)

    try do
      path
      |> File.stream!([], :line)
      |> Stream.drop(offset)
      |> maybe_take(limit)
      |> Stream.with_index(offset + 1)
      |> Enum.map(fn {line, num} ->
        "#{num}: #{String.trim_trailing(line, "\n")}"
      end)
      |> Enum.join("\n")
    rescue
      e in File.Error ->
        "Error reading file: #{Exception.message(e)}"
    end
  end

  def list_dir(path, opts \\ %{}) do
    depth = get_opt(opts, :depth, 1)
    limit = get_opt(opts, :limit, 100)

    case list_recursive(path, depth, 0, limit) do
      {:ok, entries} ->
        Enum.join(entries, "\n")

      {:error, reason} ->
        "Error listing directory: #{inspect(reason)}"
    end
  end

  defp list_recursive(path, max_depth, current_depth, limit) do
    if current_depth > max_depth do
      {:ok, []}
    else
      case File.ls(path) do
        {:ok, entries} ->
          prefix = String.duplicate("  ", current_depth)

          results =
            entries
            |> Enum.take(limit)
            |> Enum.flat_map(fn entry ->
              full_path = Path.join(path, entry)
              is_dir = File.dir?(full_path)
              marker = if is_dir, do: "/", else: ""

              current = ["#{prefix}#{entry}#{marker}"]

              if is_dir and current_depth < max_depth do
                case list_recursive(full_path, max_depth, current_depth + 1, limit) do
                  {:ok, children} -> current ++ children
                  _ -> current
                end
              else
                current
              end
            end)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def grep_files(pattern, paths, opts \\ %{}) do
    include = get_opt(opts, :include, [])
    exclude = get_opt(opts, :exclude, [])
    case_sensitive = get_opt(opts, :case_sensitive, true) != false

    flags = if case_sensitive, do: "", else: "i"

    regex =
      case Regex.compile(pattern, flags) do
        {:ok, r} -> r
        {:error, _} -> nil
      end

    if regex == nil do
      "Invalid regex pattern: #{pattern}"
    else
      results =
        paths
        |> Enum.flat_map(fn path ->
          find_files(path, include, exclude)
        end)
        |> Enum.flat_map(fn file ->
          search_file(file, regex)
        end)
        |> Enum.take(100)

      if results == [] do
        "No matches found"
      else
        Enum.join(results, "\n")
      end
    end
  end

  defp find_files(path, include, exclude) do
    cond do
      File.regular?(path) ->
        if matches_patterns?(path, include, exclude), do: [path], else: []

      File.dir?(path) ->
        case File.ls(path) do
          {:ok, entries} ->
            entries
            |> Enum.flat_map(fn entry ->
              find_files(Path.join(path, entry), include, exclude)
            end)

          _ ->
            []
        end

      true ->
        []
    end
  end

  defp matches_patterns?(path, include, exclude) do
    include_match = include == [] or Enum.any?(include, &path_matches?(path, &1))
    exclude_match = Enum.any?(exclude, &path_matches?(path, &1))
    include_match and not exclude_match
  end

  defp path_matches?(path, pattern) do
    # Simple glob matching
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> String.replace("?", ".")

    Regex.match?(~r/^#{regex_pattern}$/, path)
  end

  defp search_file(file, regex) do
    file
    |> File.stream!([], :line)
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, num} -> "#{file}:#{num}: #{String.trim(line)}" end)
  rescue
    _ -> []
  end

  defp get_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp get_opt(_opts, _key, default), do: default

  defp maybe_take(stream, nil), do: stream
  defp maybe_take(stream, limit), do: Stream.take(stream, limit)
end
