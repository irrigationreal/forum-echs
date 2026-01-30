defmodule EchsCore.ModelInfo do
  @moduledoc false

  @default_truncation_policy {:bytes, 10_000}
  @codex_truncation_policy {:tokens, 10_000}

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
      String.starts_with?(model, "gpt-5.2-codex") -> :shell_command
      String.starts_with?(model, "gpt-5.1-codex") -> :shell_command
      String.starts_with?(model, "gpt-5-codex") -> :shell_command
      String.starts_with?(model, "codex-") and not String.contains?(model, "-mini") ->
        :shell_command
      String.starts_with?(model, "exp-") -> :exec
      true -> :exec
    end
  end

  def shell_tool_type(_), do: :exec

  defp codex_shell_command_model?(model) do
    shell_tool_type(model) == :shell_command
  end
end
