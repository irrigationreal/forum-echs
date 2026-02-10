defmodule EchsCore.ToolSystem.Runner do
  @moduledoc """
  Standardized tool execution runners.

  Supports multiple execution modes:
  - `:in_process` — Elixir function call (fast, no isolation)
  - `:os_command` — OS subprocess via System.cmd or Port
  - `:pty` — PTY session for interactive tools (future)

  Each runner streams stdout/stderr as progress events and enforces
  output truncation with markers.
  """

  require Logger

  @type runner_type :: :in_process | :os_command | :pty

  @type runner_opts :: %{
          type: runner_type(),
          timeout_ms: non_neg_integer(),
          max_output_bytes: non_neg_integer(),
          env: [{String.t(), String.t()}],
          cwd: String.t() | nil,
          stream_progress: boolean()
        }

  @type runner_result :: %{
          status: :ok | :error | :timeout | :killed,
          exit_code: integer() | nil,
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          truncated: boolean()
        }

  @default_timeout 120_000
  @default_max_output 1_048_576

  @doc """
  Execute a tool using the specified runner type.
  """
  @spec run(runner_type(), term(), runner_opts()) :: runner_result()
  def run(type, invocation, opts \\ %{})

  def run(:in_process, {module, function, args}, opts) do
    timeout = Map.get(opts, :timeout_ms, @default_timeout)
    max_output = Map.get(opts, :max_output_bytes, @default_max_output)
    start = System.monotonic_time(:millisecond)

    task = Task.async(fn ->
      try do
        result = apply(module, function, args)
        {:ok, inspect(result, limit: :infinity, printable_limit: max_output)}
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end
    end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output}} ->
        duration = System.monotonic_time(:millisecond) - start
        {output, truncated} = maybe_truncate(output, max_output)
        %{status: :ok, exit_code: 0, stdout: output, stderr: "", duration_ms: duration, truncated: truncated}

      {:ok, {:error, error}} ->
        duration = System.monotonic_time(:millisecond) - start
        %{status: :error, exit_code: 1, stdout: "", stderr: error, duration_ms: duration, truncated: false}

      nil ->
        duration = System.monotonic_time(:millisecond) - start
        %{status: :timeout, exit_code: nil, stdout: "", stderr: "execution timed out after #{timeout}ms", duration_ms: duration, truncated: false}
    end
  end

  def run(:os_command, {command, args}, opts) do
    timeout = Map.get(opts, :timeout_ms, @default_timeout)
    max_output = Map.get(opts, :max_output_bytes, @default_max_output)
    cwd = Map.get(opts, :cwd)
    env = Map.get(opts, :env, [])
    start = System.monotonic_time(:millisecond)

    cmd_opts = [stderr_to_stdout: true]
    cmd_opts = if cwd, do: Keyword.put(cmd_opts, :cd, cwd), else: cmd_opts
    cmd_opts = if env != [], do: Keyword.put(cmd_opts, :env, env), else: cmd_opts

    task = Task.async(fn ->
      try do
        {output, exit_code} = System.cmd(command, args, cmd_opts)
        {output, exit_code}
      rescue
        e -> {"error: #{Exception.message(e)}", 127}
      end
    end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        duration = System.monotonic_time(:millisecond) - start
        {output, truncated} = maybe_truncate(output, max_output)
        status = if exit_code == 0, do: :ok, else: :error
        %{status: status, exit_code: exit_code, stdout: output, stderr: "", duration_ms: duration, truncated: truncated}

      nil ->
        duration = System.monotonic_time(:millisecond) - start
        %{status: :timeout, exit_code: nil, stdout: "", stderr: "command timed out after #{timeout}ms", duration_ms: duration, truncated: false}
    end
  end

  def run(:pty, _invocation, _opts) do
    %{status: :error, exit_code: nil, stdout: "", stderr: "PTY runner not yet implemented", duration_ms: 0, truncated: false}
  end

  @doc """
  Determine the appropriate runner type for a tool spec.
  """
  @spec runner_for_spec(map()) :: runner_type()
  def runner_for_spec(%{runner: runner}) when runner in [:in_process, :os_command, :pty], do: runner
  def runner_for_spec(%{type: "function"}), do: :in_process
  def runner_for_spec(%{type: "command"}), do: :os_command
  def runner_for_spec(%{type: "shell"}), do: :os_command
  def runner_for_spec(_), do: :in_process

  # --- Internal ---

  defp maybe_truncate(output, max_bytes) do
    if byte_size(output) > max_bytes do
      truncated = binary_part(output, 0, max_bytes)
      # Find last newline for clean truncation
      trunc_size = byte_size(truncated)
      search_start = trunc_size - 1
      search_len = -min(search_start, 1000)
      truncated =
        if search_start > 0 do
          case :binary.match(truncated, "\n", [{:scope, {search_start, search_len}}]) do
            {pos, _} -> binary_part(truncated, 0, pos + 1)
            :nomatch -> truncated
          end
        else
          truncated
        end

      {truncated <> "\n[... output truncated at #{max_bytes} bytes ...]", true}
    else
      {output, false}
    end
  end
end
