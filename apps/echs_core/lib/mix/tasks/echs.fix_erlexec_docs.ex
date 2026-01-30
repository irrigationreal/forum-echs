defmodule Mix.Tasks.Echs.FixErlexecDocs do
  use Mix.Task

  @shortdoc "Strips -doc/-moduledoc attributes from erlexec to avoid old compiler errors"

  @moduledoc false

  @impl true
  def run(_args) do
    deps_path = Mix.Project.deps_path()
    file = Path.join([deps_path, "erlexec", "src", "exec.erl"])

    if File.exists?(file) do
      content = File.read!(file)
      updated = strip_docs(content)

      if updated != content do
        File.write!(file, updated)
        Mix.shell().info("echs.fix_erlexec_docs: stripped docs from #{file}")
      else
        Mix.shell().info("echs.fix_erlexec_docs: no changes needed for #{file}")
      end
    else
      Mix.shell().info("echs.fix_erlexec_docs: #{file} not found, skipping")
    end
  end

  defp strip_docs(content) do
    lines = String.split(content, "\n", trim: false)
    {out, _} =
      Enum.reduce(lines, {[], false}, fn line, {acc, skipping} ->
        trimmed = String.trim_leading(line)

        cond do
          skipping ->
            if String.ends_with?(trimmed, "\"\"\".") do
              {acc, false}
            else
              {acc, true}
            end

          String.starts_with?(trimmed, "-doc") or String.starts_with?(trimmed, "-moduledoc") ->
            if String.contains?(trimmed, "\"\"\"") and not String.ends_with?(trimmed, "\"\"\".") do
              {acc, true}
            else
              {acc, false}
            end

          true ->
            {[line | acc], false}
        end
      end)

    out |> Enum.reverse() |> Enum.join("\n")
  end
end
