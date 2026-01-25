defmodule EchsCore.Tools do
  @moduledoc """
  Tool namespace.
  """

  alias EchsCore.Tools.{Shell, Files, ApplyPatch}

  defdelegate shell_execute(command, opts \\ []), to: Shell, as: :execute
  defdelegate read_file(path, opts \\ %{}), to: Files
  defdelegate list_dir(path, opts \\ %{}), to: Files
  defdelegate grep_files(pattern, paths, opts \\ %{}), to: Files
  defdelegate apply_patch(content, opts \\ []), to: ApplyPatch, as: :apply
end
