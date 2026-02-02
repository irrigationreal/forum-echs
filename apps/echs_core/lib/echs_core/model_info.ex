defmodule EchsCore.ModelInfo do
  @moduledoc false

  @default_truncation_policy {:bytes, 10_000}
  @codex_truncation_policy {:tokens, 10_000}
  @default_reasoning "medium"
  @allowed_reasoning ["none", "minimal", "low", "medium", "high", "xhigh"]

  def truncation_policy(model) when is_binary(model) do
    if codex_shell_command_model?(model) do
      @codex_truncation_policy
    else
      @default_truncation_policy
    end
  end

  def truncation_policy(_), do: @default_truncation_policy

  def shell_tool_type(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt-5.2-codex") ->
        :exec

      String.starts_with?(model, "gpt-5.2") ->
        :exec

      String.starts_with?(model, "gpt-5.1-codex") ->
        :shell_command

      String.starts_with?(model, "gpt-5-codex") ->
        :shell_command

      String.starts_with?(model, "codex-") and not String.contains?(model, "-mini") ->
        :shell_command

      claude_model?(model) ->
        :exec

      String.starts_with?(model, "exp-") ->
        :exec

      true ->
        :exec
    end
  end

  def shell_tool_type(_), do: :exec

  def apply_patch_tool_type(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt-5.2-codex") ->
        :freeform

      String.starts_with?(model, "gpt-5.1-codex") ->
        :freeform

      String.starts_with?(model, "gpt-5-codex") ->
        :freeform

      String.starts_with?(model, "codex-") and not String.contains?(model, "-mini") ->
        :freeform

      true ->
        :function
    end
  end

  def apply_patch_tool_type(_), do: :function

  def normalize_reasoning(reasoning, default \\ @default_reasoning) do
    cond do
      is_binary(reasoning) ->
        trimmed = String.trim(reasoning)
        if trimmed == "", do: default, else: normalize_reasoning_value(trimmed, default)

      reasoning == nil ->
        default

      true ->
        default
    end
  end

  def reasoning_enabled?(reasoning) when is_binary(reasoning) do
    String.trim(reasoning) != "none"
  end

  def reasoning_enabled?(_), do: true

  defp normalize_reasoning_value(value, default) do
    if value in @allowed_reasoning do
      value
    else
      default
    end
  end

  defp codex_shell_command_model?(model) do
    shell_tool_type(model) == :shell_command
  end

  defp claude_model?(model) when is_binary(model) do
    normalized = model |> String.trim() |> String.downcase()
    normalized in ["opus", "sonnet", "haiku"] or String.starts_with?(normalized, "claude-")
  end

  defp claude_model?(_), do: false
end
