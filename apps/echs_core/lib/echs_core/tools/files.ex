defmodule EchsCore.Tools.Files do
  @moduledoc """
  File operation tools: read_file, list_dir, grep_files.
  """

  def read_file_spec do
    %{
      "type" => "function",
      "name" => "read_file",
      "description" =>
        "Reads a local file with 1-indexed line numbers, supporting slice and indentation-aware block modes.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Absolute path to the file"
          },
          "offset" => %{
            "type" => "number",
            "description" => "The line number to start reading from. Must be 1 or greater."
          },
          "limit" => %{
            "type" => "number",
            "description" => "The maximum number of lines to return."
          },
          "mode" => %{
            "type" => "string",
            "description" =>
              "Optional mode selector: \"slice\" for simple ranges (default) or \"indentation\" to expand around an anchor line."
          },
          "indentation" => %{
            "type" => "object",
            "properties" => %{
              "anchor_line" => %{
                "type" => "number",
                "description" =>
                  "Anchor line to center the indentation lookup on (defaults to offset)."
              },
              "max_levels" => %{
                "type" => "number",
                "description" =>
                  "How many parent indentation levels (smaller indents) to include."
              },
              "include_siblings" => %{
                "type" => "boolean",
                "description" =>
                  "When true, include additional blocks that share the anchor indentation."
              },
              "include_header" => %{
                "type" => "boolean",
                "description" =>
                  "Include doc comments or attributes directly above the selected block."
              },
              "max_lines" => %{
                "type" => "number",
                "description" =>
                  "Hard cap on the number of lines returned when using indentation mode."
              }
            },
            "additionalProperties" => false
          }
        },
        "required" => ["file_path"],
        "additionalProperties" => false
      }
    }
  end

  def list_dir_spec do
    %{
      "type" => "function",
      "name" => "list_dir",
      "description" =>
        "Lists entries in a local directory with 1-indexed entry numbers and simple type labels.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" => "Absolute path to the directory to list."
          },
          "offset" => %{
            "type" => "number",
            "description" => "The entry number to start listing from. Must be 1 or greater."
          },
          "limit" => %{
            "type" => "number",
            "description" => "The maximum number of entries to return."
          },
          "depth" => %{
            "type" => "number",
            "description" => "The maximum directory depth to traverse. Must be 1 or greater."
          }
        },
        "required" => ["dir_path"],
        "additionalProperties" => false
      }
    }
  end

  def grep_files_spec do
    %{
      "type" => "function",
      "name" => "grep_files",
      "description" =>
        "Finds files whose contents match the pattern and lists them by modification time.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regular expression pattern to search for."
          },
          "include" => %{
            "type" => "string",
            "description" =>
              "Optional glob that limits which files are searched (e.g. \"*.rs\" or \"*.{ts,tsx}\")."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Directory or file path to search. Defaults to the session's working directory."
          },
          "limit" => %{
            "type" => "number",
            "description" => "Maximum number of file paths to return (defaults to 100)."
          }
        },
        "required" => ["pattern"],
        "additionalProperties" => false
      }
    }
  end

  @max_line_length 500
  @tab_width 4
  @comment_prefixes ["#", "//", "--"]

  def read_file(path, opts \\ %{}) do
    offset = get_opt(opts, :offset, 1)
    limit = get_opt(opts, :limit, 2000)
    mode = get_opt(opts, :mode, "slice")

    cond do
      offset == 0 ->
        {:error, "offset must be a 1-indexed line number"}

      limit == 0 ->
        {:error, "limit must be greater than zero"}

      Path.type(path) != :absolute ->
        {:error, "file_path must be an absolute path"}

      true ->
        case mode do
          "indentation" ->
            indentation = get_opt(opts, :indentation, %{})
            read_file_indentation(path, offset, limit, indentation)

          _ ->
            read_file_slice(path, offset, limit)
        end
    end
  end

  def list_dir(path, opts \\ %{}) do
    offset = get_opt(opts, :offset, 1)
    limit = get_opt(opts, :limit, 25)
    depth = get_opt(opts, :depth, 2)

    cond do
      offset == 0 ->
        {:error, "offset must be a 1-indexed entry number"}

      limit == 0 ->
        {:error, "limit must be greater than zero"}

      depth == 0 ->
        {:error, "depth must be greater than zero"}

      Path.type(path) != :absolute ->
        {:error, "dir_path must be an absolute path"}

      true ->
        case list_dir_slice(path, offset, limit, depth) do
          {:ok, entries} ->
            output = ["Absolute path: #{path}"] ++ entries
            Enum.join(output, "\n")

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def grep_files(pattern, opts \\ %{}) do
    pattern = to_string(pattern || "")
    include = get_opt(opts, :include, nil)
    path = get_opt(opts, :path, nil)
    limit = get_opt(opts, :limit, 100)
    cwd = get_opt(opts, :cwd, File.cwd!())

    pattern = String.trim(pattern || "")

    cond do
      pattern == "" ->
        {:error, "pattern must not be empty"}

      limit == 0 ->
        {:error, "limit must be greater than zero"}

      true ->
        limit = min(limit, 2000)
        search_path = resolve_path(path, cwd)

        with :ok <- verify_path_exists(search_path),
             {:ok, results} <- run_rg_search(pattern, include, search_path, limit, cwd) do
          if results == [] do
            "No matches found."
          else
            Enum.join(results, "\n")
          end
        end
    end
  end

  defp read_file_slice(path, offset, limit) do
    case File.read(path) do
      {:ok, data} ->
        lines = split_lines(data)

        if length(lines) < offset do
          {:error, "offset exceeds file length"}
        else
          selected =
            lines
            |> Enum.drop(offset - 1)
            |> Enum.take(limit)
            |> Enum.with_index(offset)
            |> Enum.map(fn {line, num} ->
              "L#{num}: #{format_line(line)}"
            end)

          Enum.join(selected, "\n")
        end

      {:error, reason} ->
        {:error, "failed to read file: #{:file.format_error(reason)}"}
    end
  end

  defp read_file_indentation(path, offset, limit, indentation) do
    anchor_line = get_opt(indentation, :anchor_line, nil) || offset

    if anchor_line == 0 do
      {:error, "anchor_line must be a 1-indexed line number"}
    else
      max_levels = get_opt(indentation, :max_levels, 0)
      include_siblings = get_opt(indentation, :include_siblings, false)
      include_header = get_opt(indentation, :include_header, true)
      max_lines = get_opt(indentation, :max_lines, nil)

      guard_limit = max_lines || limit

      if guard_limit == 0 do
        {:error, "max_lines must be greater than zero"}
      else
        case File.read(path) do
          {:ok, data} ->
            records = build_line_records(data)

            if records == [] or anchor_line > length(records) do
              {:error, "anchor_line exceeds file length"}
            else
              anchor_index = anchor_line - 1
              effective_indents = effective_indents(records)
              anchor_indent = Enum.at(effective_indents, anchor_index)

              min_indent =
                if max_levels == 0 do
                  0
                else
                  max(anchor_indent - max_levels * @tab_width, 0)
                end

              final_limit =
                limit
                |> min(guard_limit)
                |> min(length(records))

              if final_limit == 1 do
                record = Enum.at(records, anchor_index)
                "L#{record.number}: #{record.display}"
              else
                out =
                  collect_indented(
                    records,
                    effective_indents,
                    anchor_index,
                    min_indent,
                    final_limit,
                    include_siblings,
                    include_header
                  )

                out =
                  out
                  |> trim_empty_lines()
                  |> Enum.map(fn record -> "L#{record.number}: #{record.display}" end)

                Enum.join(out, "\n")
              end
            end

          {:error, reason} ->
            {:error, "failed to read file: #{:file.format_error(reason)}"}
        end
      end
    end
  end

  defp build_line_records(data) when is_binary(data) do
    data
    |> split_lines()
    |> Enum.with_index(1)
    |> Enum.map(fn {line, num} ->
      %{
        number: num,
        raw: line,
        display: format_line(line),
        indent: measure_indent(line)
      }
    end)
  end

  defp effective_indents(records) do
    {indents, _} =
      Enum.map_reduce(records, 0, fn record, prev ->
        if String.trim(record.raw) == "" do
          {prev, prev}
        else
          {record.indent, record.indent}
        end
      end)

    indents
  end

  defp collect_indented(
         records,
         effective_indents,
         anchor_index,
         min_indent,
         final_limit,
         include_siblings,
         include_header
       ) do
    out = :queue.new()
    out = :queue.in(Enum.at(records, anchor_index), out)

    i = anchor_index - 1
    j = anchor_index + 1
    i_counter_min = 0
    j_counter_min = 0

    {out, _} =
      Enum.reduce_while(Stream.cycle([:step]), {out, {i, j, i_counter_min, j_counter_min}}, fn _,
                                                                                                 {queue,
                                                                                                  {iu, ju,
                                                                                                   i_cnt,
                                                                                                   j_cnt}} ->
        if :queue.len(queue) >= final_limit do
          {:halt, {queue, {iu, ju, i_cnt, j_cnt}}}
        else
          {queue, {iu, ju, i_cnt, j_cnt}, progressed} =
            step_collect(
              records,
              effective_indents,
              queue,
              iu,
              ju,
              min_indent,
              include_siblings,
              include_header,
              i_cnt,
              j_cnt
            )

          if progressed == 0 do
            {:halt, {queue, {iu, ju, i_cnt, j_cnt}}}
          else
            {:cont, {queue, {iu, ju, i_cnt, j_cnt}}}
          end
        end
      end)

    :queue.to_list(out)
  end

  defp step_collect(
         records,
         effective_indents,
         queue,
         i,
         j,
         min_indent,
         include_siblings,
         include_header,
         i_counter_min,
         j_counter_min
       ) do
    progressed = 0

    {queue1, i1, i_counter_min1, progressed1} =
      if i >= 0 do
        idx = i
        if Enum.at(effective_indents, idx) >= min_indent do
          record = Enum.at(records, idx)
          queue_up = :queue.in_r(record, queue)
          progressed_up = progressed + 1
          i_up = i - 1

          if Enum.at(effective_indents, idx) == min_indent and not include_siblings do
            allow_header_comment = include_header and comment_line?(record.raw)
            can_take_line = allow_header_comment or i_counter_min == 0

            if can_take_line do
              {queue_up, i_up, i_counter_min + 1, progressed_up}
            else
              queue_up = :queue.out_r(queue_up) |> elem(1)
              {queue_up, -1, i_counter_min, progressed_up - 1}
            end
          else
            {queue_up, i_up, i_counter_min, progressed_up}
          end
        else
          {queue, -1, i_counter_min, progressed}
        end
      else
        {queue, i, i_counter_min, progressed}
      end

    {queue2, j1, j_counter_min1, progressed2} =
      if j < length(records) do
        idx = j
        if Enum.at(effective_indents, idx) >= min_indent do
          record = Enum.at(records, idx)
          queue_down = :queue.in(record, queue1)
          progressed_down = progressed1 + 1
          j_down = j + 1

          if Enum.at(effective_indents, idx) == min_indent and not include_siblings do
            if j_counter_min > 0 do
              queue_down = :queue.out(queue_down) |> elem(1)
              {queue_down, length(records), j_counter_min + 1, progressed_down - 1}
            else
              {queue_down, j_down, j_counter_min + 1, progressed_down}
            end
          else
            {queue_down, j_down, j_counter_min, progressed_down}
          end
        else
          {queue1, length(records), j_counter_min, progressed1}
        end
      else
        {queue1, j, j_counter_min, progressed1}
      end

    {queue2, {i1, j1, i_counter_min1, j_counter_min1}, progressed2}
  end

  defp trim_empty_lines(records) do
    records
    |> drop_while_front(&blank_line?/1)
    |> drop_while_back(&blank_line?/1)
  end

  defp drop_while_front(list, fun) do
    Enum.drop_while(list, fun)
  end

  defp drop_while_back(list, fun) do
    list
    |> Enum.reverse()
    |> Enum.drop_while(fun)
    |> Enum.reverse()
  end

  defp blank_line?(record) do
    String.trim(record.raw) == ""
  end

  defp comment_line?(line) do
    trimmed = String.trim(line)
    Enum.any?(@comment_prefixes, &String.starts_with?(trimmed, &1))
  end

  defp measure_indent(line) do
    line
    |> String.to_charlist()
    |> Enum.take_while(fn ch -> ch == ?\s or ch == ?\t end)
    |> Enum.reduce(0, fn ch, acc ->
      if ch == ?\t, do: acc + @tab_width, else: acc + 1
    end)
  end

  defp format_line(line) when is_binary(line) do
    if byte_size(line) > @max_line_length do
      take_bytes_at_char_boundary(line, @max_line_length)
    else
      line
    end
  end

  defp take_bytes_at_char_boundary(text, limit) do
    cond do
      limit <= 0 ->
        ""

      byte_size(text) <= limit ->
        text

      true ->
        binary_part = binary_part(text, 0, limit)

        if String.valid?(binary_part) do
          binary_part
        else
          take_bytes_at_char_boundary(text, limit - 1)
        end
    end
  end

  defp split_lines(data) when is_binary(data) do
    lines =
      data
      |> String.split("\n", trim: false)
      |> Enum.map(fn line ->
        if String.ends_with?(line, "\r") do
          String.trim_trailing(line, "\r")
        else
          line
        end
      end)

    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp list_dir_slice(path, offset, limit, depth) do
    case collect_entries(path, "", depth) do
      {:ok, entries} ->
        entries = Enum.sort_by(entries, & &1.name)

        if entries == [] do
          {:ok, []}
        else
          start_index = offset - 1

          if start_index >= length(entries) do
            {:error, "offset exceeds directory entry count"}
          else
            remaining = length(entries) - start_index
            capped_limit = min(limit, remaining)
            end_index = start_index + capped_limit
            selected = Enum.slice(entries, start_index, capped_limit)

            formatted = Enum.map(selected, &format_entry_line/1)

            formatted =
              if end_index < length(entries) do
                formatted ++ ["More than #{capped_limit} entries found"]
              else
                formatted
              end

            {:ok, formatted}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_entries(dir_path, prefix, depth) do
    queue = [{dir_path, prefix, depth}]
    do_collect_entries(queue, [])
  end

  defp do_collect_entries([], entries), do: {:ok, entries}

  defp do_collect_entries([{current_dir, prefix, remaining_depth} | rest], entries) do
    case File.ls(current_dir) do
      {:ok, dir_entries} ->
        dir_entries =
          Enum.map(dir_entries, fn entry ->
            entry_path = Path.join(current_dir, entry)
            relative_path = if prefix == "", do: entry, else: Path.join(prefix, entry)
            display_depth = if prefix == "", do: 0, else: length(Path.split(prefix))

            case entry_kind_and_name(entry_path, entry) do
              {:ok, kind, display_name} ->
                {:ok,
                 %{
                   name: format_entry_name(relative_path),
                   display_name: display_name,
                   depth: display_depth,
                   kind: kind,
                   entry_path: entry_path,
                   relative_path: relative_path
                 }}

              {:error, reason} ->
                {:error, reason}
            end
          end)

        case Enum.find(dir_entries, &match?({:error, _}, &1)) do
          {:error, reason} ->
            {:error, reason}

          nil ->
            dir_entries =
              dir_entries
              |> Enum.map(fn {:ok, entry} -> entry end)
              |> Enum.sort_by(& &1.name)

            {next_queue, entries} =
              Enum.reduce(dir_entries, {rest, entries}, fn entry, {queue_acc, entries_acc} ->
                queue_acc =
                  if entry.kind == :directory and remaining_depth > 1 do
                    queue_acc ++ [{entry.entry_path, entry.relative_path, remaining_depth - 1}]
                  else
                    queue_acc
                  end

                {queue_acc, entries_acc ++ [entry]}
              end)

            do_collect_entries(next_queue, entries)
        end

      {:error, reason} ->
        {:error, "failed to read directory: #{:file.format_error(reason)}"}
    end
  end

  defp entry_kind_and_name(path, entry) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, :symlink, format_entry_component(entry)}

      {:ok, %File.Stat{type: :directory}} ->
        {:ok, :directory, format_entry_component(entry)}

      {:ok, %File.Stat{type: :regular}} ->
        {:ok, :file, format_entry_component(entry)}

      {:ok, _} ->
        {:ok, :other, format_entry_component(entry)}

      {:error, reason} ->
        {:error, "failed to inspect entry: #{:file.format_error(reason)}"}
    end
  end

  defp format_entry_name(path) do
    normalized =
      path
      |> to_string()
      |> String.replace("\\", "/")

    if byte_size(normalized) > @max_line_length do
      take_bytes_at_char_boundary(normalized, @max_line_length)
    else
      normalized
    end
  end

  defp format_entry_component(name) do
    text = to_string(name)

    if byte_size(text) > @max_line_length do
      take_bytes_at_char_boundary(text, @max_line_length)
    else
      text
    end
  end

  defp format_entry_line(entry) do
    indent = String.duplicate(" ", entry.depth * 2)

    suffix =
      case entry.kind do
        :directory -> "/"
        :symlink -> "@"
        :other -> "?"
        _ -> ""
      end

    "#{indent}#{entry.display_name}#{suffix}"
  end

  defp resolve_path(nil, cwd), do: cwd
  defp resolve_path("", cwd), do: cwd

  defp resolve_path(path, cwd) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, cwd)
    end
  end

  defp verify_path_exists(path) do
    case File.stat(path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "unable to access `#{path}`: #{:file.format_error(reason)}"}
    end
  end

  defp run_rg_search(pattern, include, search_path, limit, cwd) do
    args =
      ["--files-with-matches", "--sortr=modified", "--regexp", pattern, "--no-messages"] ++
        if is_binary(include) and String.trim(include) != "" do
          ["--glob", include]
        else
          []
        end ++ ["--", search_path]

    task =
      Task.async(fn ->
        System.cmd("rg", args, cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, parse_rg_results(output, limit)}

      {:ok, {_output, 1}} ->
        {:ok, []}

      {:ok, {output, _exit_code}} ->
        {:error, "rg failed: #{output}"}

      nil ->
        {:error, "rg timed out after 30 seconds"}
    end
  rescue
    e ->
      {:error,
       "failed to launch rg: #{Exception.message(e)}. Ensure ripgrep is installed and on PATH."}
  end

  defp parse_rg_results(output, limit) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.take(limit)
  end

  defp get_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp get_opt(_opts, _key, default), do: default
end
