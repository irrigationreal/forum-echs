defmodule EchsCore.Tools.ApplyPatchInvocation do
  @moduledoc false

  alias EchsCore.Tools.ApplyPatch

  @apply_patch_commands ["apply_patch", "applypatch"]
  @implicit_invocation_message "patch detected without explicit call to apply_patch. Rerun as [\"apply_patch\", \"<patch>\"]"

  def maybe_parse_verified(argv, cwd) when is_list(argv) do
    cwd = Path.expand(cwd || File.cwd!())

    case detect_implicit_invocation(argv) do
      :implicit ->
        {:error, @implicit_invocation_message}

      :ok ->
        maybe_parse_apply_patch(argv, cwd)
    end
  end

  defp detect_implicit_invocation([body]) when is_binary(body) do
    case ApplyPatch.parse(body) do
      {:ok, _} -> :implicit
      {:error, _} -> :ok
    end
  end

  defp detect_implicit_invocation(argv) when is_list(argv) do
    case parse_shell_script(argv) do
      {:ok, _shell, script} when is_binary(script) ->
        case ApplyPatch.parse(script) do
          {:ok, _} -> :implicit
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_parse_apply_patch(argv, cwd) do
    case argv do
      [cmd, body] when cmd in @apply_patch_commands and is_binary(body) ->
        case ApplyPatch.parse(body) do
          {:ok, _parsed} ->
            {:ok, %{patch: body, cwd: cwd}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        case parse_shell_script(argv) do
          {:ok, _shell, script} ->
            case extract_apply_patch_from_script(script) do
              {:ok, {body, workdir}} ->
                effective_cwd = resolve_workdir(cwd, workdir)

                case ApplyPatch.parse(body) do
                  {:ok, _parsed} ->
                    {:ok, %{patch: body, cwd: effective_cwd}}

                  {:error, reason} ->
                    {:error, reason}
                end

              :not_apply_patch ->
                :not_apply_patch

              {:error, _reason} ->
                :not_apply_patch
            end

          _ ->
            :not_apply_patch
        end
    end
  end

  defp resolve_workdir(cwd, nil), do: cwd

  defp resolve_workdir(cwd, workdir) do
    case Path.type(workdir) do
      :absolute -> Path.expand(workdir)
      :relative -> Path.expand(Path.join(cwd, workdir))
    end
  end

  defp parse_shell_script([shell, flag, script]) when is_binary(shell) and is_binary(flag) do
    case classify_shell(shell, flag) do
      nil -> :error
      shell_type -> {:ok, shell_type, script}
    end
  end

  defp parse_shell_script([shell, skip_flag, flag, script])
       when is_binary(shell) and is_binary(skip_flag) and is_binary(flag) do
    if can_skip_flag?(shell, skip_flag) do
      case classify_shell(shell, flag) do
        nil -> :error
        shell_type -> {:ok, shell_type, script}
      end
    else
      :error
    end
  end

  defp parse_shell_script(_), do: :error

  defp classify_shell(shell, flag) do
    case classify_shell_name(shell) do
      "bash" -> if flag in ["-lc", "-c"], do: :unix, else: nil
      "zsh" -> if flag in ["-lc", "-c"], do: :unix, else: nil
      "sh" -> if flag in ["-lc", "-c"], do: :unix, else: nil
      "powershell" -> if String.downcase(flag) == "-command", do: :powershell, else: nil
      "pwsh" -> if String.downcase(flag) == "-command", do: :powershell, else: nil
      "cmd" -> if String.downcase(flag) == "/c", do: :cmd, else: nil
      _ -> nil
    end
  end

  defp classify_shell_name(shell) do
    shell
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
  end

  defp can_skip_flag?(shell, flag) do
    case classify_shell_name(shell) do
      "powershell" -> String.downcase(flag) == "-noprofile"
      "pwsh" -> String.downcase(flag) == "-noprofile"
      _ -> false
    end
  end

  defp extract_apply_patch_from_script(script) when is_binary(script) do
    script = String.trim(script)

    with {:ok, workdir, rest} <- extract_cd_prefix(script),
         {:ok, body} <- extract_apply_patch_body(rest) do
      {:ok, {body, workdir}}
    else
      :no_prefix ->
        case extract_apply_patch_body(script) do
          {:ok, body} -> {:ok, {body, nil}}
          other -> other
        end

      :not_apply_patch ->
        :not_apply_patch

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_cd_prefix(script) do
    case Regex.run(~r/^cd\s+/, script) do
      [match] ->
        rest = String.slice(script, byte_size(match), byte_size(script) - byte_size(match))
        {path, remainder} = parse_cd_path(rest)

        if path == nil do
          :not_apply_patch
        else
          case parse_and_strip_and(remainder) do
            {:ok, after_and} -> {:ok, path, after_and}
            :not_apply_patch -> :not_apply_patch
          end
        end

      _ ->
        :no_prefix
    end
  end

  defp parse_cd_path(rest) do
    rest = String.trim_leading(rest)

    cond do
      String.starts_with?(rest, "'") ->
        case split_quoted(rest, "'") do
          {:ok, value, remainder} -> {value, remainder}
          :error -> {nil, rest}
        end

      String.starts_with?(rest, "\"") ->
        case split_quoted(rest, "\"") do
          {:ok, value, remainder} -> {value, remainder}
          :error -> {nil, rest}
        end

      true ->
        case String.split(rest, ~r/\s+/, parts: 2) do
          [path, remainder] -> {path, remainder}
          [path] -> {path, ""}
        end
    end
  end

  defp split_quoted(<<quote::binary-size(1), rest::binary>>, quote) do
    case String.split(rest, quote, parts: 2) do
      [value, remainder] -> {:ok, value, remainder}
      _ -> :error
    end
  end

  defp split_quoted(_, _), do: :error

  defp parse_and_strip_and(remainder) do
    remainder = String.trim_leading(remainder)

    if String.starts_with?(remainder, "&&") do
      {:ok, String.trim_leading(String.trim_leading(remainder, "&&"))}
    else
      :not_apply_patch
    end
  end

  defp extract_apply_patch_body(script) do
    case match_apply_patch_prefix(script) do
      {:ok, rest} ->
        parse_heredoc_body(rest)

      :not_apply_patch ->
        :not_apply_patch
    end
  end

  defp match_apply_patch_prefix(script) do
    case script do
      <<"apply_patch", rest::binary>> -> {:ok, String.trim_leading(rest)}
      <<"applypatch", rest::binary>> -> {:ok, String.trim_leading(rest)}
      _ -> :not_apply_patch
    end
  end

  defp parse_heredoc_body(rest) do
    rest = String.trim_leading(rest)

    with true <- String.starts_with?(rest, "<<"),
         {label, body} <- parse_heredoc_label(rest),
         {:ok, body_text} <- parse_heredoc_content(body, label) do
      {:ok, body_text}
    else
      _ -> :not_apply_patch
    end
  end

  defp parse_heredoc_label("<<" <> rest) do
    rest = String.trim_leading(rest)

    {label, remainder} =
      cond do
        String.starts_with?(rest, "'") ->
          case split_quoted(rest, "'") do
            {:ok, value, tail} -> {value, tail}
            :error -> {nil, rest}
          end

        String.starts_with?(rest, "\"") ->
          case split_quoted(rest, "\"") do
            {:ok, value, tail} -> {value, tail}
            :error -> {nil, rest}
          end

        true ->
          case String.split(rest, ~r/\s+/, parts: 2) do
            [value, tail] -> {value, tail}
            [value] -> {value, ""}
          end
      end

    label = if label == "", do: nil, else: label

    {label, remainder}
  end

  defp parse_heredoc_content(remainder, label) when is_binary(label) do
    content =
      if String.starts_with?(remainder, "\n") do
        String.slice(remainder, 1, byte_size(remainder) - 1)
      else
        remainder
      end

    lines = String.split(content, "\n", trim: false)

    case Enum.split_while(lines, fn line -> normalize_line(line) != label end) do
      {body_lines, [end_line | rest]} ->
        if normalize_line(end_line) == label and Enum.all?(rest, &blank_line?/1) do
          body = Enum.join(body_lines, "\n") |> String.trim_trailing("\n")
          {:ok, body}
        else
          :not_apply_patch
        end

      _ ->
        :not_apply_patch
    end
  end

  defp parse_heredoc_content(_, _), do: :not_apply_patch

  defp blank_line?(line) do
    String.trim(line) == ""
  end

  defp normalize_line(line) do
    if String.ends_with?(line, "\r") do
      String.trim_trailing(line, "\r")
    else
      line
    end
  end
end
