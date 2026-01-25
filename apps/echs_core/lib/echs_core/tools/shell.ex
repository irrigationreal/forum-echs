defmodule EchsCore.Tools.Shell do
  @moduledoc """
  Shell command execution tool.
  """

  def spec do
    %{
      "type" => "function",
      "name" => "shell",
      "description" => "Execute a shell command",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell command to execute"
          },
          "workdir" => %{
            "type" => "string",
            "description" => "Working directory (optional)"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: 120000)"
          }
        },
        "required" => ["command"]
      }
    }
  end

  @doc """
  Execute a shell command.
  Returns formatted output for the model.
  """
  def execute(command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        {output, exit_code} =
          System.cmd("bash", ["-lc", command],
            cd: cwd,
            stderr_to_stdout: true,
            env: [{"TERM", "dumb"}],
            timeout: timeout
          )

        {:ok, output, exit_code}
      rescue
        e ->
          {:error, Exception.message(e)}
      catch
        :exit, {:timeout, _} ->
          {:error, :timeout}
      end

    duration = (System.monotonic_time(:millisecond) - start_time) / 1000

    case result do
      {:ok, output, exit_code} ->
        format_output(output, exit_code, duration)

      {:error, :timeout} ->
        "Exit code: -1\nWall time: #{duration} seconds\nOutput:\nCommand timed out after #{timeout}ms"

      {:error, message} ->
        "Exit code: -1\nWall time: #{duration} seconds\nOutput:\nError: #{message}"
    end
  end

  defp format_output(output, exit_code, duration) do
    # Truncate if too long
    max_length = 100_000

    truncated =
      if String.length(output) > max_length do
        String.slice(output, 0, max_length) <> "\n... [truncated]"
      else
        output
      end

    """
    Exit code: #{exit_code}
    Wall time: #{Float.round(duration, 3)} seconds
    Output:
    #{truncated}
    """
  end
end
