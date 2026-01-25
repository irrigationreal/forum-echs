defmodule EchsCore.Tools.ApplyPatch do
  @moduledoc """
  Apply patch tool using the Codex "*** Begin Patch" format.
  """

  def spec do
    %{
      "type" => "function",
      "name" => "apply_patch",
      "description" => "Apply a patch to modify files. Use the *** Begin Patch format.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "patch" => %{
            "type" => "string",
            "description" => "The patch content in *** Begin Patch format"
          }
        },
        "required" => ["patch"]
      }
    }
  end

  @doc """
  Apply a patch string to files.
  """
  def apply(patch_content, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case parse_patch(patch_content) do
      {:ok, operations} ->
        results =
          Enum.map(operations, fn op ->
            apply_operation(op, cwd)
          end)

        errors =
          Enum.filter(results, fn
            {:error, _} -> true
            _ -> false
          end)

        if errors == [] do
          files = Enum.map(operations, & &1.file)
          "Success. Updated the following files: #{Enum.join(files, ", ")}"
        else
          error_msgs = Enum.map(errors, fn {:error, msg} -> msg end)
          "Failed to apply patch: #{Enum.join(error_msgs, "; ")}"
        end

      {:error, reason} ->
        "Failed to parse patch: #{reason}"
    end
  end

  defp parse_patch(content) do
    # Parse the *** Begin Patch format
    lines = String.split(content, "\n")

    case parse_operations(lines, []) do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      error -> error
    end
  end

  defp parse_operations([], acc), do: {:ok, acc}

  defp parse_operations(["*** Begin Patch" | rest], acc) do
    parse_operations(rest, acc)
  end

  defp parse_operations(["*** End Patch" | rest], acc) do
    parse_operations(rest, acc)
  end

  defp parse_operations(["*** Update File: " <> file | rest], acc) do
    {hunks, remaining} = collect_hunks(rest, [])
    op = %{type: :update, file: String.trim(file), hunks: hunks}
    parse_operations(remaining, [op | acc])
  end

  defp parse_operations(["*** Add File: " <> file | rest], acc) do
    {content_lines, remaining} = collect_until_marker(rest, [])
    # Strip leading + from lines (patch format)
    content_lines =
      Enum.map(content_lines, fn
        "+" <> line -> line
        line -> line
      end)

    content = Enum.join(content_lines, "\n")
    op = %{type: :add, file: String.trim(file), content: content}
    parse_operations(remaining, [op | acc])
  end

  defp parse_operations(["*** Delete File: " <> file | rest], acc) do
    op = %{type: :delete, file: String.trim(file)}
    parse_operations(rest, [op | acc])
  end

  defp parse_operations(["" | rest], acc) do
    parse_operations(rest, acc)
  end

  defp parse_operations([_line | rest], acc) do
    # Skip unknown lines
    parse_operations(rest, acc)
  end

  defp collect_hunks(lines, acc) do
    case lines do
      ["@@" <> _ = hunk_header | rest] ->
        {hunk_lines, remaining} = collect_hunk_lines(rest, [])
        hunk = %{header: hunk_header, lines: hunk_lines}
        collect_hunks(remaining, [hunk | acc])

      ["@@@" <> _ = hunk_header | rest] ->
        {hunk_lines, remaining} = collect_hunk_lines(rest, [])
        hunk = %{header: hunk_header, lines: hunk_lines}
        collect_hunks(remaining, [hunk | acc])

      _ ->
        {Enum.reverse(acc), lines}
    end
  end

  defp collect_hunk_lines([], acc), do: {Enum.reverse(acc), []}

  defp collect_hunk_lines(["@@" <> _ | _] = rest, acc) do
    {Enum.reverse(acc), rest}
  end

  defp collect_hunk_lines(["@@@" <> _ | _] = rest, acc) do
    {Enum.reverse(acc), rest}
  end

  defp collect_hunk_lines(["*** " <> _ | _] = rest, acc) do
    {Enum.reverse(acc), rest}
  end

  defp collect_hunk_lines([line | rest], acc) do
    collect_hunk_lines(rest, [line | acc])
  end

  defp collect_until_marker([], acc), do: {Enum.reverse(acc), []}

  defp collect_until_marker(["*** " <> _ | _] = rest, acc) do
    {Enum.reverse(acc), rest}
  end

  defp collect_until_marker([line | rest], acc) do
    collect_until_marker(rest, [line | acc])
  end

  defp apply_operation(%{type: :add, file: file, content: content}, cwd) do
    full_path = Path.join(cwd, file)

    # Create directory if needed
    dir = Path.dirname(full_path)
    File.mkdir_p!(dir)

    case File.write(full_path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create #{file}: #{inspect(reason)}"}
    end
  end

  defp apply_operation(%{type: :delete, file: file}, cwd) do
    full_path = Path.join(cwd, file)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to delete #{file}: #{inspect(reason)}"}
    end
  end

  defp apply_operation(%{type: :update, file: file, hunks: hunks}, cwd) do
    full_path = Path.join(cwd, file)

    case File.read(full_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        case apply_hunks(lines, hunks) do
          {:ok, new_lines} ->
            new_content = Enum.join(new_lines, "\n")

            case File.write(full_path, new_content) do
              :ok -> :ok
              {:error, reason} -> {:error, "Failed to write #{file}: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Failed to apply hunk to #{file}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{file}: #{inspect(reason)}"}
    end
  end

  defp apply_hunks(lines, hunks) do
    # Apply hunks in reverse order to preserve line numbers
    sorted_hunks =
      Enum.sort_by(hunks, fn hunk ->
        case parse_hunk_header(hunk.header) do
          {:ok, start, _} -> -start
          _ -> 0
        end
      end)

    Enum.reduce_while(sorted_hunks, {:ok, lines}, fn hunk, {:ok, current_lines} ->
      case apply_single_hunk(current_lines, hunk) do
        {:ok, new_lines} -> {:cont, {:ok, new_lines}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_hunk_header(header) do
    # Parse "@@ -start,count +start,count @@" or "@@@ -start,count +start,count @@@"
    case Regex.run(~r/@+\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@+/, header) do
      [_, old_start, _, _, _] ->
        {:ok, String.to_integer(old_start), 0}

      _ ->
        {:error, "Invalid hunk header: #{header}"}
    end
  end

  defp apply_single_hunk(lines, hunk) do
    case parse_hunk_header(hunk.header) do
      {:ok, start_line, _} ->
        # Find context match
        {before_lines, from_line} = find_context_match(lines, hunk.lines, start_line)

        if from_line >= 0 do
          # Apply the changes
          {new_middle, skip_count} = apply_hunk_lines(hunk.lines)
          after_lines = Enum.drop(lines, from_line + skip_count)

          {:ok, before_lines ++ new_middle ++ after_lines}
        else
          {:error, "Could not find context match for hunk starting at line #{start_line}"}
        end

      error ->
        error
    end
  end

  defp find_context_match(lines, hunk_lines, suggested_start) do
    # Try to find where the hunk applies
    lines_len = length(lines)
    suggested_index = max(0, suggested_start - 1)

    context_lines =
      hunk_lines
      |> Enum.filter(fn line ->
        String.starts_with?(line, " ") or String.starts_with?(line, "-")
      end)
      |> Enum.map(fn
        " " <> rest -> rest
        "-" <> rest -> rest
      end)

    if context_lines == [] do
      # No context to match, use suggested start
      {Enum.take(lines, suggested_index), suggested_index}
    else
      # Try to find the context
      first_context = List.first(context_lines)

      # Search around the suggested start
      search_range = max(0, suggested_index - 10)..(suggested_index + 10)

      match_pos =
        Enum.find(search_range, fn i ->
          i >= 0 and i < lines_len and Enum.at(lines, i) == first_context
        end)

      if match_pos do
        {Enum.take(lines, match_pos), match_pos}
      else
        # Fall back to suggested start
        {Enum.take(lines, suggested_index), suggested_index}
      end
    end
  end

  defp apply_hunk_lines(hunk_lines) do
    {result, skip} =
      Enum.reduce(hunk_lines, {[], 0}, fn line, {acc, skip_count} ->
        cond do
          String.starts_with?(line, "+") ->
            # Add line (without the +)
            {[String.slice(line, 1..-1//1) | acc], skip_count}

          String.starts_with?(line, "-") ->
            # Remove line (skip it in original)
            {acc, skip_count + 1}

          String.starts_with?(line, " ") ->
            # Context line
            {[String.slice(line, 1..-1//1) | acc], skip_count + 1}

          true ->
            # Unknown, treat as context
            {[line | acc], skip_count + 1}
        end
      end)

    {Enum.reverse(result), skip}
  end
end
