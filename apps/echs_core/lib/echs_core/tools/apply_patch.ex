defmodule EchsCore.Tools.ApplyPatch do
  @moduledoc """
  Apply patch tool using the Codex "*** Begin Patch" format.
  """

  @begin_patch "*** Begin Patch"
  @end_patch "*** End Patch"
  @add_file "*** Add File: "
  @delete_file "*** Delete File: "
  @update_file "*** Update File: "
  @move_to "*** Move to: "
  @end_of_file "*** End of File"
  @change_context "@@ "
  @empty_change_context "@@"

  def spec do
    %{
      "type" => "function",
      "name" => "apply_patch",
      "description" => ~s"""
      Use the `apply_patch` tool to edit files.
      Your patch language is a stripped‑down, file‑oriented diff format designed to be easy to parse and safe to apply. You can think of it as a high‑level envelope:

      *** Begin Patch
      [ one or more file sections ]
      *** End Patch

      Within that envelope, you get a sequence of file operations.
      You MUST include a header to specify the action you are taking.
      Each operation starts with one of three headers:

      *** Add File: <path> - create a new file. Every following line is a + line (the initial contents).
      *** Delete File: <path> - remove an existing file. Nothing follows.
      *** Update File: <path> - patch an existing file in place (optionally with a rename).

      May be immediately followed by *** Move to: <new path> if you want to rename the file.
      Then one or more “hunks”, each introduced by @@ (optionally followed by a hunk header).
      Within a hunk each line starts with:

      For instructions on [context_before] and [context_after]:
      - By default, show 3 lines of code immediately above and 3 lines immediately below each change. If a change is within 3 lines of a previous change, do NOT duplicate the first change’s [context_after] lines in the second change’s [context_before] lines.
      - If 3 lines of context is insufficient to uniquely identify the snippet of code within the file, use the @@ operator to indicate the class or function to which the snippet belongs. For instance, we might have:
      @@ class BaseClass
      [3 lines of pre-context]
      - [old_code]
      + [new_code]
      [3 lines of post-context]

      - If a code block is repeated so many times in a class or function such that even a single `@@` statement and 3 lines of context cannot uniquely identify the snippet of code, you can use multiple `@@` statements to jump to the right context. For instance:

      @@ class BaseClass
      @@ 	 def method():
      [3 lines of pre-context]
      - [old_code]
      + [new_code]
      [3 lines of post-context]

      The full grammar definition is below:
      Patch := Begin { FileOp } End
      Begin := "*** Begin Patch" NEWLINE
      End := "*** End Patch" NEWLINE
      FileOp := AddFile | DeleteFile | UpdateFile
      AddFile := "*** Add File: " path NEWLINE { "+" line NEWLINE }
      DeleteFile := "*** Delete File: " path NEWLINE
      UpdateFile := "*** Update File: " path NEWLINE [ MoveTo ] { Hunk }
      MoveTo := "*** Move to: " newPath NEWLINE
      Hunk := "@@" [ header ] NEWLINE { HunkLine } [ "*** End of File" NEWLINE ]
      HunkLine := (" " | "-" | "+") text NEWLINE

      A full patch can combine several operations:

      *** Begin Patch
      *** Add File: hello.txt
      +Hello world
      *** Update File: src/app.py
      *** Move to: src/main.py
      @@ def greet():
      -print("Hi")
      +print("Hello, world!")
      *** Delete File: obsolete.txt
      *** End Patch

      It is important to remember:

      - You must include a header with your intended action (Add/Delete/Update)
      - You must prefix new lines with `+` even when creating a new file
      - File references can only be relative, NEVER ABSOLUTE.
      """,
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "input" => %{
            "type" => "string",
            "description" => "The entire contents of the apply_patch command"
          }
        },
        "required" => ["input"],
        "additionalProperties" => false
      }
    }
  end

  def spec(_tool_type), do: spec()

  @doc """
  Apply a patch string to files.
  """
  def apply(patch_content, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case parse_patch(patch_content) do
      {:ok, %{hunks: hunks}} ->
        case apply_hunks(hunks, cwd) do
          {:ok, affected} ->
            print_summary(affected)

          {:error, reason} when is_binary(reason) ->
            {:error, "apply_patch verification failed: #{reason}"}
        end

      {:error, reason} when is_binary(reason) ->
        {:error, "apply_patch verification failed: #{reason}"}
    end
  end

  @doc false
  def parse(patch_content) do
    parse_patch(patch_content)
  end

  defp parse_patch(patch) do
    lines =
      patch
      |> to_string()
      |> String.trim()
      |> String.split("\n", trim: false)
      |> Enum.map(fn line ->
        if String.ends_with?(line, "\r") do
          String.trim_trailing(line, "\r")
        else
          line
        end
      end)

    lines_result =
      case check_patch_boundaries_strict(lines) do
        :ok ->
          {:ok, lines}

        {:error, reason} ->
          check_patch_boundaries_lenient(lines, reason)
      end

    case lines_result do
      {:ok, lines} ->
        last_index = max(length(lines) - 1, 0)
        remaining = Enum.slice(lines, 1, last_index - 1)

        parse_hunks(remaining, 2, [])
        |> case do
          {:ok, hunks} ->
            {:ok, %{hunks: hunks, patch: Enum.join(lines, "\n")}}

          {:error, err} ->
            {:error, err}
        end

      {:error, err} ->
        {:error, err}
    end
  end

  defp check_patch_boundaries_strict(lines) do
    first = List.first(lines)
    last = List.last(lines)

    first = if is_binary(first), do: String.trim(first), else: nil
    last = if is_binary(last), do: String.trim(last), else: nil

    cond do
      first == @begin_patch and last == @end_patch ->
        :ok

      first != @begin_patch ->
        {:error, "invalid patch: The first line of the patch must be '*** Begin Patch'"}

      true ->
        {:error, "invalid patch: The last line of the patch must be '*** End Patch'"}
    end
  end

  defp check_patch_boundaries_lenient(lines, original_error) do
    case lines do
      [first | _] = all when length(all) >= 4 ->
        last = List.last(all)

        heredoc =
          first in ["<<EOF", "<<'EOF'", "<<\"EOF\""] and is_binary(last) and
            String.ends_with?(last, "EOF")

        if heredoc do
          inner = Enum.slice(all, 1, length(all) - 2)

          case check_patch_boundaries_strict(inner) do
            :ok -> {:ok, inner}
            {:error, err} -> {:error, err}
          end
        else
          {:error, original_error}
        end

      _ ->
        {:error, original_error}
    end
  end

  defp parse_hunks([], _line_number, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_hunks(lines, line_number, acc) do
    case parse_one_hunk(lines, line_number) do
      {:ok, {hunk, lines_consumed}} ->
        remaining = Enum.slice(lines, lines_consumed, length(lines))
        parse_hunks(remaining, line_number + lines_consumed, [hunk | acc])

      {:error, err} ->
        {:error, err}
    end
  end

  defp parse_one_hunk(lines, line_number) do
    first_line = lines |> List.first() |> String.trim()

    cond do
      String.starts_with?(first_line, @add_file) ->
        path = String.replace_prefix(first_line, @add_file, "")
        {contents, consumed} = parse_add_lines(Enum.drop(lines, 1), "", 0)
        {:ok, {%{type: :add, path: path, contents: contents}, consumed + 1}}

      String.starts_with?(first_line, @delete_file) ->
        path = String.replace_prefix(first_line, @delete_file, "")
        {:ok, {%{type: :delete, path: path}, 1}}

      String.starts_with?(first_line, @update_file) ->
        path = String.replace_prefix(first_line, @update_file, "")
        {move_path, remaining, consumed} = parse_move_line(Enum.drop(lines, 1), 1)

        parse_update_chunks(remaining, line_number + consumed, [], 0)
        |> case do
          {:ok, {chunks, chunk_lines}} ->
            if chunks == [] do
              {:error,
               "invalid hunk at line #{line_number}, Update file hunk for path '#{path}' is empty"}
            else
              {:ok,
               {%{type: :update, path: path, move_path: move_path, chunks: chunks},
                consumed + chunk_lines}}
            end

          {:error, err} ->
            {:error, err}
        end

      true ->
        {:error,
         "invalid hunk at line #{line_number}, '#{first_line}' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'"}
    end
  end

  defp parse_add_lines(lines, acc, consumed)

  defp parse_add_lines([line | rest], acc, consumed) do
    if String.starts_with?(line, "+") do
      parse_add_lines(rest, acc <> String.replace_prefix(line, "+", "") <> "\n", consumed + 1)
    else
      {acc, consumed}
    end
  end

  defp parse_add_lines([], acc, consumed), do: {acc, consumed}

  defp parse_move_line([line | rest], consumed) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, @move_to) do
      {String.replace_prefix(trimmed, @move_to, ""), rest, consumed + 1}
    else
      {nil, [line | rest], consumed}
    end
  end

  defp parse_move_line([], consumed), do: {nil, [], consumed}

  defp parse_update_chunks(lines, line_number, acc, consumed) do
    cond do
      lines == [] ->
        {:ok, {Enum.reverse(acc), consumed}}

      String.trim(List.first(lines)) == "" ->
        parse_update_chunks(Enum.drop(lines, 1), line_number + 1, acc, consumed + 1)

      String.starts_with?(List.first(lines), "***") ->
        {:ok, {Enum.reverse(acc), consumed}}

      true ->
        case parse_update_chunk(lines, line_number, acc == []) do
          {:ok, {chunk, used}} ->
            rest = Enum.slice(lines, used, length(lines))
            parse_update_chunks(rest, line_number + used, [chunk | acc], consumed + used)

          {:error, err} ->
            {:error, err}
        end
    end
  end

  defp parse_update_chunk(lines, line_number, allow_missing_context) do
    [first | _] = lines

    {change_context, start_index} =
      cond do
        first == @empty_change_context ->
          {nil, 1}

        String.starts_with?(first, @change_context) ->
          {String.replace_prefix(first, @change_context, ""), 1}

        allow_missing_context ->
          {nil, 0}

        true ->
          {nil, :error}
      end

    if start_index == :error do
      {:error,
       "invalid hunk at line #{line_number}, Expected update hunk to start with a @@ context marker, got: '#{first}'"}
    else
      if start_index >= length(lines) do
        {:error,
         "invalid hunk at line #{line_number + 1}, Update hunk does not contain any lines"}
      else
        chunk = %{
          change_context: change_context,
          old_lines: [],
          new_lines: [],
          is_end_of_file: false
        }

        parse_update_lines(Enum.drop(lines, start_index), line_number + 1, chunk, 0)
        |> case do
          {:ok, {chunk_out, consumed}} ->
            {:ok, {chunk_out, consumed + start_index}}

          {:error, err} ->
            {:error, err}
        end
      end
    end
  end

  defp parse_update_lines([], line_number, chunk, parsed_lines) do
    if parsed_lines == 0 do
      {:error, "invalid hunk at line #{line_number}, Update hunk does not contain any lines"}
    else
      {:ok, {chunk, parsed_lines}}
    end
  end

  defp parse_update_lines([line | rest], line_number, chunk, parsed_lines) do
    cond do
      line == @end_of_file ->
        if parsed_lines == 0 do
          {:error, "invalid hunk at line #{line_number}, Update hunk does not contain any lines"}
        else
          chunk = %{chunk | is_end_of_file: true}
          {:ok, {chunk, parsed_lines + 1}}
        end

      true ->
        case String.first(line) do
          nil ->
            chunk = %{
              chunk
              | old_lines: chunk.old_lines ++ [""],
                new_lines: chunk.new_lines ++ [""]
            }

            parse_update_lines(rest, line_number + 1, chunk, parsed_lines + 1)

          " " ->
            text = String.slice(line, 1..-1//1)

            chunk = %{
              chunk
              | old_lines: chunk.old_lines ++ [text],
                new_lines: chunk.new_lines ++ [text]
            }

            parse_update_lines(rest, line_number + 1, chunk, parsed_lines + 1)

          "+" ->
            text = String.slice(line, 1..-1//1)
            chunk = %{chunk | new_lines: chunk.new_lines ++ [text]}
            parse_update_lines(rest, line_number + 1, chunk, parsed_lines + 1)

          "-" ->
            text = String.slice(line, 1..-1//1)
            chunk = %{chunk | old_lines: chunk.old_lines ++ [text]}
            parse_update_lines(rest, line_number + 1, chunk, parsed_lines + 1)

          _ ->
            if parsed_lines == 0 do
              {:error,
               "invalid hunk at line #{line_number}, Unexpected line found in update hunk: '#{line}'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"}
            else
              {:ok, {chunk, parsed_lines}}
            end
        end
    end
  end

  defp apply_hunks([], _cwd), do: {:error, "No files were modified."}

  defp apply_hunks(hunks, cwd) do
    added = []
    modified = []
    deleted = []

    Enum.reduce_while(
      hunks,
      {:ok, %{added: added, modified: modified, deleted: deleted}},
      fn hunk, {:ok, acc} ->
        case apply_hunk(hunk, cwd) do
          {:ok, {:add, path}} ->
            {:cont, {:ok, %{acc | added: acc.added ++ [path]}}}

          {:ok, {:delete, path}} ->
            {:cont, {:ok, %{acc | deleted: acc.deleted ++ [path]}}}

          {:ok, {:modify, path}} ->
            {:cont, {:ok, %{acc | modified: acc.modified ++ [path]}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp apply_hunk(%{type: :add, path: path, contents: contents}, cwd) do
    full_path = Path.expand(path, cwd)

    with :ok <- ensure_parent_dirs(full_path),
         :ok <- File.write(full_path, contents) do
      {:ok, {:add, full_path}}
    else
      {:error, reason} ->
        {:error, "Failed to write file #{full_path}: #{:file.format_error(reason)}"}
    end
  end

  defp apply_hunk(%{type: :delete, path: path}, cwd) do
    full_path = Path.expand(path, cwd)

    case File.rm(full_path) do
      :ok ->
        {:ok, {:delete, full_path}}

      {:error, reason} ->
        {:error, "Failed to delete file #{full_path}: #{:file.format_error(reason)}"}
    end
  end

  defp apply_hunk(%{type: :update, path: path, move_path: move_path, chunks: chunks}, cwd) do
    full_path = Path.expand(path, cwd)

    case derive_new_contents_from_chunks(full_path, chunks) do
      {:ok, new_contents} ->
        dest =
          if move_path do
            Path.expand(move_path, cwd)
          else
            full_path
          end

        with :ok <- ensure_parent_dirs(dest),
             :ok <- File.write(dest, new_contents),
             :ok <- maybe_remove_original(full_path, dest) do
          {:ok, {:modify, dest}}
        else
          {:error, reason} ->
            {:error, "Failed to write file #{dest}: #{:file.format_error(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_parent_dirs(path) do
    dir = Path.dirname(path)

    if dir != "" and dir != "." do
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_remove_original(src, dest) do
    if src == dest do
      :ok
    else
      case File.rm(src) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, "Failed to remove original #{src}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp derive_new_contents_from_chunks(path, chunks) do
    case File.read(path) do
      {:ok, content} ->
        original_lines =
          content
          |> String.split("\n", trim: false)
          |> drop_trailing_empty_line()

        case compute_replacements(original_lines, path, chunks) do
          {:ok, replacements} ->
            new_lines = apply_replacements(original_lines, replacements)
            new_lines = ensure_trailing_newline(new_lines)
            {:ok, Enum.join(new_lines, "\n")}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to read file to update #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp drop_trailing_empty_line(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp ensure_trailing_newline(lines) do
    case List.last(lines) do
      "" -> lines
      _ -> lines ++ [""]
    end
  end

  defp compute_replacements(original_lines, path, chunks) do
    Enum.reduce_while(chunks, {:ok, {[], 0}}, fn chunk, {:ok, {acc, line_index}} ->
      line_index =
        if chunk.change_context do
          case seek_sequence(original_lines, [chunk.change_context], line_index, false) do
            nil -> {:error, "Failed to find context '#{chunk.change_context}' in #{path}"}
            idx -> idx + 1
          end
        else
          line_index
        end

      case line_index do
        {:error, reason} ->
          {:halt, {:error, reason}}

        idx when chunk.old_lines == [] ->
          insertion_idx =
            if List.last(original_lines) == "" do
              max(length(original_lines) - 1, 0)
            else
              length(original_lines)
            end

          {:cont, {:ok, {acc ++ [{insertion_idx, 0, chunk.new_lines}], idx}}}

        idx ->
          pattern = chunk.old_lines
          new_lines = chunk.new_lines

          found = seek_sequence(original_lines, pattern, idx, chunk.is_end_of_file)

          {pattern, new_lines, found} =
            if found == nil and List.last(pattern) == "" do
              pattern = Enum.drop(pattern, -1)
              new_lines = maybe_drop_trailing_empty(new_lines)
              found = seek_sequence(original_lines, pattern, idx, chunk.is_end_of_file)
              {pattern, new_lines, found}
            else
              {pattern, new_lines, found}
            end

          case found do
            nil ->
              {:halt,
               {:error,
                "Failed to find expected lines in #{path}:\n#{Enum.join(chunk.old_lines, "\n")}"}}

            start_idx ->
              {:cont,
               {:ok,
                {acc ++ [{start_idx, length(pattern), new_lines}], start_idx + length(pattern)}}}
          end
      end
    end)
    |> case do
      {:ok, {replacements, _}} ->
        {:ok, Enum.sort_by(replacements, fn {idx, _, _} -> idx end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_drop_trailing_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp apply_replacements(lines, replacements) do
    Enum.reduce(Enum.reverse(replacements), lines, fn {start_idx, old_len, new_segment}, acc ->
      acc = remove_range(acc, start_idx, old_len)
      insert_range(acc, start_idx, new_segment)
    end)
  end

  defp remove_range(lines, start_idx, count) do
    Enum.take(lines, start_idx) ++ Enum.drop(lines, start_idx + count)
  end

  defp insert_range(lines, start_idx, segment) do
    {head, tail} = Enum.split(lines, start_idx)
    head ++ segment ++ tail
  end

  defp seek_sequence(lines, pattern, start, eof) do
    cond do
      pattern == [] ->
        start

      length(pattern) > length(lines) ->
        nil

      true ->
        search_start =
          if eof and length(lines) >= length(pattern) do
            length(lines) - length(pattern)
          else
            start
          end

        case seek_exact(lines, pattern, search_start) do
          nil ->
            case seek_trim(lines, pattern, search_start, :rstrip) do
              nil ->
                case seek_trim(lines, pattern, search_start, :both) do
                  nil -> seek_normalized(lines, pattern, search_start)
                  idx -> idx
                end

              idx ->
                idx
            end

          idx ->
            idx
        end
    end
  end

  defp seek_exact(lines, pattern, start) do
    max_idx = length(lines) - length(pattern)

    Enum.find_value(start..max_idx, fn i ->
      if Enum.slice(lines, i, length(pattern)) == pattern, do: i, else: nil
    end)
  end

  defp seek_trim(lines, pattern, start, mode) do
    max_idx = length(lines) - length(pattern)

    Enum.find_value(start..max_idx, fn i ->
      ok =
        Enum.with_index(pattern)
        |> Enum.all?(fn {pat, idx} ->
          line = Enum.at(lines, i + idx)

          case mode do
            :rstrip -> String.trim_trailing(line) == String.trim_trailing(pat)
            :both -> String.trim(line) == String.trim(pat)
          end
        end)

      if ok, do: i, else: nil
    end)
  end

  defp seek_normalized(lines, pattern, start) do
    max_idx = length(lines) - length(pattern)

    Enum.find_value(start..max_idx, fn i ->
      ok =
        Enum.with_index(pattern)
        |> Enum.all?(fn {pat, idx} ->
          line = Enum.at(lines, i + idx)
          normalize(line) == normalize(pat)
        end)

      if ok, do: i, else: nil
    end)
  end

  defp normalize(text) do
    text
    |> String.trim()
    |> String.to_charlist()
    |> Enum.map(fn ch ->
      case ch do
        0x2010 -> ?-
        0x2011 -> ?-
        0x2012 -> ?-
        0x2013 -> ?-
        0x2014 -> ?-
        0x2015 -> ?-
        0x2212 -> ?-
        0x2018 -> ?'
        0x2019 -> ?'
        0x201A -> ?'
        0x201B -> ?'
        0x201C -> ?"
        0x201D -> ?"
        0x201E -> ?"
        0x201F -> ?"
        0x00A0 -> ?\s
        0x2002 -> ?\s
        0x2003 -> ?\s
        0x2004 -> ?\s
        0x2005 -> ?\s
        0x2006 -> ?\s
        0x2007 -> ?\s
        0x2008 -> ?\s
        0x2009 -> ?\s
        0x200A -> ?\s
        0x202F -> ?\s
        0x205F -> ?\s
        0x3000 -> ?\s
        other -> other
      end
    end)
    |> List.to_string()
  end

  defp print_summary(%{added: added, modified: modified, deleted: deleted}) do
    header = "Success. Updated the following files:"

    lines =
      Enum.map(added, fn path -> "A #{path}" end) ++
        Enum.map(modified, fn path -> "M #{path}" end) ++
        Enum.map(deleted, fn path -> "D #{path}" end)

    Enum.join([header | lines], "\n") <> "\n"
  end
end
