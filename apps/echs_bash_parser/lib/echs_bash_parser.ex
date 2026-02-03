defmodule EchsBashParser do
  @moduledoc """
  Shell command parsing and safety validation using tree-sitter-bash.

  This module provides functions to parse shell commands and validate
  they don't contain unsafe constructs like command substitution,
  process substitution, or dangerous redirections.
  """

  use Rustler,
    otp_app: :echs_bash_parser,
    crate: "echs_bash_parser"

  @doc """
  Parses a shell script and returns the list of plain commands.

  Returns `{:ok, commands}` where commands is a list of command argument lists,
  or `{:error, reason}` if the script contains unsafe constructs.

  ## Examples

      iex> EchsBashParser.parse_shell_commands("ls -la")
      {:ok, [["ls", "-la"]]}

      iex> EchsBashParser.parse_shell_commands("echo hello && cat file.txt")
      {:ok, [["echo", "hello"], ["cat", "file.txt"]]}

      iex> EchsBashParser.parse_shell_commands("echo $(whoami)")
      {:error, :unsafe_construct}

  """
  @spec parse_shell_commands(String.t()) :: {:ok, [[String.t()]]} | {:error, atom()}
  def parse_shell_commands(_script), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if a command is known to be safe (read-only).

  Safe commands are those that don't modify the filesystem or system state.

  ## Examples

      iex> EchsBashParser.is_safe_command?(["ls", "-la"])
      true

      iex> EchsBashParser.is_safe_command?(["rm", "-rf", "/"])
      false

  """
  @spec is_safe_command?([String.t()]) :: boolean()
  def is_safe_command?(command), do: is_safe_command(command)

  # NIF stub - name must match Rust function exactly (no ? suffix in NIFs)
  @doc false
  @spec is_safe_command([String.t()]) :: boolean()
  def is_safe_command(_command), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validates a shell script for safety.

  Returns `:ok` if the script is safe to execute, or `{:error, reason}` otherwise.
  """
  @spec validate_script(String.t()) :: :ok | {:error, String.t()}
  def validate_script(script) do
    case parse_shell_commands(script) do
      {:ok, _commands} -> :ok
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp format_error(:unsafe_construct), do: "Command contains unsafe shell constructs"
  defp format_error(:parse_error), do: "Failed to parse shell command"
  defp format_error(reason), do: "Shell validation failed: #{inspect(reason)}"
end
