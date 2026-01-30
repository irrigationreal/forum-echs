defmodule EchsCore.Tools.Truncate do
  @moduledoc false

  @approx_bytes_per_token 4

  def formatted_truncate_text(content, policy) when is_binary(content) do
    if byte_size(content) <= byte_budget(policy) do
      content
    else
      total_lines = line_count(content)
      result = truncate_text(content, policy)
      "Total output lines: #{total_lines}\n\n#{result}"
    end
  end

  def truncate_text(content, policy) when is_binary(content) do
    case policy do
      {:bytes, _} -> truncate_with_byte_estimate(content, policy)
      {:tokens, _} -> truncate_with_token_budget(content, policy) |> elem(0)
    end
  end

  def approx_token_count(text) when is_binary(text) do
    div(byte_size(text) + @approx_bytes_per_token - 1, @approx_bytes_per_token)
  end

  def approx_bytes_for_tokens(tokens) when is_integer(tokens) and tokens > 0 do
    tokens * @approx_bytes_per_token
  end

  def approx_bytes_for_tokens(_tokens), do: 0

  def approx_tokens_from_byte_count(bytes) when is_integer(bytes) and bytes > 0 do
    div(bytes + @approx_bytes_per_token - 1, @approx_bytes_per_token)
  end

  def approx_tokens_from_byte_count(_bytes), do: 0

  def line_count(content) do
    normalized = String.replace(content, "\r\n", "\n")
    lines = String.split(normalized, "\n", trim: false)

    lines =
      case List.last(lines) do
        "" -> Enum.drop(lines, -1)
        _ -> lines
      end

    length(lines)
  end

  defp truncate_with_token_budget(content, policy) do
    if content == "" do
      {"", nil}
    else
      max_tokens = token_budget(policy)
      byte_len = byte_size(content)

      if max_tokens > 0 and byte_len <= approx_bytes_for_tokens(max_tokens) do
        {content, nil}
      else
        truncated = truncate_with_byte_estimate(content, policy)
        original = approx_token_count(content)

        if truncated == content do
          {truncated, nil}
        else
          {truncated, original}
        end
      end
    end
  end

  defp truncate_with_byte_estimate(content, policy) do
    if content == "" do
      ""
    else
      total_chars = String.length(content)
      max_bytes = byte_budget(policy)

      cond do
        max_bytes == 0 ->
          marker = format_truncation_marker(policy, removed_units_for_source(policy, byte_size(content), total_chars))
          marker

        byte_size(content) <= max_bytes ->
          content

        true ->
          total_bytes = byte_size(content)
          {left_budget, right_budget} = split_budget(max_bytes)
          {removed_chars, left, right} = split_string(content, left_budget, right_budget)

          marker =
            format_truncation_marker(
              policy,
              removed_units_for_source(
                policy,
                total_bytes - max_bytes,
                removed_chars
              )
            )

          assemble_truncated_output(left, right, marker)
      end
    end
  end

  defp split_string(content, beginning_bytes, end_bytes) do
    if content == "" do
      {0, "", ""}
    else
      len = byte_size(content)
      tail_start_target = max(len - end_bytes, 0)

      {prefix_end, suffix_start, removed_chars, _pos, _suffix_started} =
        Enum.reduce(String.codepoints(content), {0, len, 0, 0, false}, fn cp,
                                                                           {prefix_end_acc,
                                                                            suffix_start_acc,
                                                                            removed_acc,
                                                                            pos,
                                                                            suffix_started_acc} ->
          char_bytes = byte_size(cp)
          char_end = pos + char_bytes

          cond do
            char_end <= beginning_bytes ->
              {char_end, suffix_start_acc, removed_acc, char_end, suffix_started_acc}

            pos >= tail_start_target ->
              if suffix_started_acc do
                {prefix_end_acc, suffix_start_acc, removed_acc, char_end, suffix_started_acc}
              else
                {prefix_end_acc, pos, removed_acc, char_end, true}
              end

            true ->
              {prefix_end_acc, suffix_start_acc, removed_acc + 1, char_end, suffix_started_acc}
          end
        end)

      suffix_start = if suffix_start < prefix_end, do: prefix_end, else: suffix_start

      before = if prefix_end == 0, do: "", else: binary_part(content, 0, prefix_end)

      suffix =
        if suffix_start >= len do
          ""
        else
          binary_part(content, suffix_start, len - suffix_start)
        end

      {removed_chars, before, suffix}
    end
  end

  defp format_truncation_marker(policy, removed_count) do
    case policy do
      {:tokens, _} -> "…#{removed_count} tokens truncated…"
      {:bytes, _} -> "…#{removed_count} chars truncated…"
    end
  end

  defp split_budget(budget) do
    left = div(budget, 2)
    {left, budget - left}
  end

  defp removed_units_for_source(policy, removed_bytes, removed_chars) do
    case policy do
      {:tokens, _} -> approx_tokens_from_byte_count(removed_bytes)
      {:bytes, _} -> removed_chars
    end
  end

  defp assemble_truncated_output(prefix, suffix, marker) do
    prefix <> marker <> suffix
  end

  defp byte_budget(policy) do
    case policy do
      {:bytes, bytes} when is_integer(bytes) and bytes > 0 -> bytes
      {:tokens, tokens} when is_integer(tokens) and tokens > 0 -> approx_bytes_for_tokens(tokens)
      _ -> 0
    end
  end

  defp token_budget(policy) do
    case policy do
      {:tokens, tokens} when is_integer(tokens) and tokens > 0 -> tokens
      {:bytes, bytes} when is_integer(bytes) and bytes > 0 -> approx_tokens_from_byte_count(bytes)
      _ -> 0
    end
  end
end
