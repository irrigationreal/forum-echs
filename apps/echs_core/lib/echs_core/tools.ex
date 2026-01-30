defmodule EchsCore.Tools do
  @moduledoc """
  Tool namespace.
  """

  alias EchsCore.Tools.{Shell, Files, ApplyPatch}

  defdelegate shell_execute(command, opts \\ []), to: Shell, as: :execute_array
  defdelegate read_file(path, opts \\ %{}), to: Files
  defdelegate list_dir(path, opts \\ %{}), to: Files
  def grep_files(pattern, path, opts \\ %{}) do
    Files.grep_files(pattern, Map.put(opts, :path, path))
  end
  defdelegate apply_patch(content, opts \\ []), to: ApplyPatch, as: :apply
end
