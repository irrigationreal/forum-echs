defmodule EchsCore.Tools.Shell do
  @moduledoc """
  Shell command execution tools.
  """

  alias EchsCore.Tools.Exec
  alias EchsCore.Tools.ExecEnv
  alias EchsCore.Tools.Truncate

  @default_truncation_policy {:tokens, 10_000}
  @timeout_exit_code 192
  @post_exit_grace_ms 50
  @exec_output_max_bytes 1_048_576

  def spec do
    %{
      "type" => "function",
      "name" => "shell",
      "description" =>
        if match?({:win32, _}, :os.type()) do
          ~s"""
          Runs a Powershell command (Windows) and returns its output. Arguments to `shell` will be passed to CreateProcessW(). Most commands should be prefixed with ["powershell.exe", "-Command"].

          Examples of valid command strings:

          - ls -a (show hidden): ["powershell.exe", "-Command", "Get-ChildItem -Force"]
          - recursive find by name: ["powershell.exe", "-Command", "Get-ChildItem -Recurse -Filter *.py"]
          - recursive grep: ["powershell.exe", "-Command", "Get-ChildItem -Path C:\\myrepo -Recurse | Select-String -Pattern 'TODO' -CaseSensitive"]
          - ps aux | grep python: ["powershell.exe", "-Command", "Get-Process | Where-Object { $_.ProcessName -like '*python*' }"]
          - setting an env var: ["powershell.exe", "-Command", "$env:FOO='bar'; echo $env:FOO"]
          - running an inline Python script: ["powershell.exe", "-Command", "@'\\nprint('Hello, world!')\\n'@ | python -"]
          """
        else
          ~s"""
          Runs a shell command and returns its output.
          - The arguments to `shell` will be passed to execvp(). Most terminal commands should be prefixed with ["bash", "-lc"].
          - Always set the `workdir` param when using the shell function. Do not use `cd` unless absolutely necessary.
          """
        end,
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "The command to execute"
          },
          "workdir" => %{
            "type" => "string",
            "description" => "The working directory to execute the command in"
          },
          "timeout_ms" => %{
            "type" => "number",
            "description" => "The timeout for the command in milliseconds"
          },
          "sandbox_permissions" => %{
            "type" => "string",
            "description" =>
              "Sandbox permissions for the command. Set to \"require_escalated\" to request running without sandbox restrictions; defaults to \"use_default\"."
          },
          "justification" => %{
            "type" => "string",
            "description" =>
              "Only set if sandbox_permissions is \"require_escalated\". \n                    Request approval from the user to run this command outside the sandbox. \n                    Phrased as a simple question that summarizes the purpose of the \n                    command as it relates to the task at hand - e.g. 'Do you want to \n                    fetch and pull the latest version of this git branch?'"
          },
          "prefix_rule" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Only specify when sandbox_permissions is `require_escalated`. \n                    Suggest a prefix command pattern that will allow you to fulfill similar requests from the user in the future.\n                    Should be a short but reasonable prefix, e.g. [\"git\", \"pull\"] or [\"uv\", \"run\"] or [\"pytest\"]."
          }
        },
        "required" => ["command"],
        "additionalProperties" => false
      }
    }
  end

  def shell_command_spec do
    %{
      "type" => "function",
      "name" => "shell_command",
      "description" =>
        if match?({:win32, _}, :os.type()) do
          ~s"""
          Runs a Powershell command (Windows) and returns its output.

          Examples of valid command strings:

          - ls -a (show hidden): "Get-ChildItem -Force"
          - recursive find by name: "Get-ChildItem -Recurse -Filter *.py"
          - recursive grep: "Get-ChildItem -Path C:\\myrepo -Recurse | Select-String -Pattern 'TODO' -CaseSensitive"
          - ps aux | grep python: "Get-Process | Where-Object { $_.ProcessName -like '*python*' }"
          - setting an env var: "$env:FOO='bar'; echo $env:FOO"
          - running an inline Python script: "@'\\nprint('Hello, world!')\\n'@ | python -"
          """
        else
          ~s"""
          Runs a shell command and returns its output.
          - Always set the `workdir` param when using the shell_command function. Do not use `cd` unless absolutely necessary.
          """
        end,
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell script to execute in the user's default shell"
          },
          "workdir" => %{
            "type" => "string",
            "description" => "The working directory to execute the command in"
          },
          "login" => %{
            "type" => "boolean",
            "description" =>
              "Whether to run the shell with login shell semantics. Defaults to true."
          },
          "timeout_ms" => %{
            "type" => "number",
            "description" => "The timeout for the command in milliseconds"
          },
          "sandbox_permissions" => %{
            "type" => "string",
            "description" =>
              "Sandbox permissions for the command. Set to \"require_escalated\" to request running without sandbox restrictions; defaults to \"use_default\"."
          },
          "justification" => %{
            "type" => "string",
            "description" =>
              "Only set if sandbox_permissions is \"require_escalated\". \n                    Request approval from the user to run this command outside the sandbox. \n                    Phrased as a simple question that summarizes the purpose of the \n                    command as it relates to the task at hand - e.g. 'Do you want to \n                    fetch and pull the latest version of this git branch?'"
          },
          "prefix_rule" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Only specify when sandbox_permissions is `require_escalated`. \n                    Suggest a prefix command pattern that will allow you to fulfill similar requests from the user in the future.\n                    Should be a short but reasonable prefix, e.g. [\"git\", \"pull\"] or [\"uv\", \"run\"] or [\"pytest\"]."
          }
        },
        "required" => ["command"],
        "additionalProperties" => false
      }
    }
  end

  def execute_array(argv, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout_ms, 120_000)
    truncation_policy = Keyword.get(opts, :truncation_policy, @default_truncation_policy)

    case argv do
      [cmd | _rest] when is_binary(cmd) ->
        case run_command(argv, cwd, timeout) do
          {:ok, stdout, stderr, exit_code, duration_ms, timed_out} ->
            output = aggregate_output(stdout, stderr)
            format_structured(output, exit_code, duration_ms, timed_out, truncation_policy)

          {:error, message, duration_ms} ->
            format_structured(
              "execution error: #{message}",
              -1,
              duration_ms,
              false,
              truncation_policy
            )
        end

      _ ->
        {:error, "unsupported payload for shell handler: shell"}
    end
  end

  def execute_command(command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout_ms, 120_000)
    login = Keyword.get(opts, :login, true)
    truncation_policy = Keyword.get(opts, :truncation_policy, @default_truncation_policy)
    shell = Keyword.get(opts, :shell, System.get_env("SHELL") || "/bin/bash")

    argv = Exec.command_args(shell, command, login)

    case run_command(argv, cwd, timeout) do
      {:ok, stdout, stderr, exit_code, duration_ms, timed_out} ->
        output = aggregate_output(stdout, stderr)
        format_freeform(output, exit_code, duration_ms, timed_out, truncation_policy)

      {:error, message, duration_ms} ->
        format_freeform("execution error: #{message}", -1, duration_ms, false, truncation_policy)
    end
  end

  def format_freeform_output(output, exit_code, duration_ms, timed_out, truncation_policy) do
    format_freeform(output, exit_code, duration_ms, timed_out, truncation_policy)
  end

  defp run_command(argv, cwd, timeout_ms) do
    _ = Application.ensure_all_started(:erlexec)
    start_time = System.monotonic_time(:millisecond)
    env = ExecEnv.create_env()
    exec_opts = build_exec_opts(cwd, env)

    case :exec.run(argv, exec_opts) do
      {:ok, _pid, os_pid} ->
        {stdout, stderr, exit_code, timed_out} =
          collect_shell_output(os_pid, timeout_ms)

        duration_ms = System.monotonic_time(:millisecond) - start_time
        exit_code = if exit_code == nil, do: -1, else: exit_code
        {:ok, stdout, stderr, exit_code, duration_ms, timed_out}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        {:error, inspect(reason), duration_ms}
    end
  end

  defp build_exec_opts(cwd, env) do
    env_list = Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
    [:monitor, :stdout, :stderr, {:cd, cwd}, {:env, env_list}]
  end

  defp collect_shell_output(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {stdout, stderr, exit_code, timed_out} =
      loop_collect(os_pid, [], [], deadline, nil, false, nil)

    exit_code = maybe_infer_exit_code(exit_code, os_pid)
    {stdout, stderr, exit_code, timed_out}
  end

  defp loop_collect(os_pid, out_acc, err_acc, deadline, exit_code, timed_out, exit_grace_deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline and exit_code == nil and not timed_out ->
        :exec.stop(os_pid)
        new_exit_code = @timeout_exit_code
        new_grace = now + @post_exit_grace_ms
        loop_collect(os_pid, out_acc, err_acc, deadline, new_exit_code, true, new_grace)

      exit_code != nil and exit_grace_deadline != nil and now >= exit_grace_deadline ->
        {out_acc |> Enum.reverse() |> IO.iodata_to_binary(),
         err_acc |> Enum.reverse() |> IO.iodata_to_binary(), exit_code, timed_out}

      now >= deadline and exit_code != nil ->
        {out_acc |> Enum.reverse() |> IO.iodata_to_binary(),
         err_acc |> Enum.reverse() |> IO.iodata_to_binary(), exit_code, timed_out}

      true ->
        timeout =
          cond do
            exit_code != nil and exit_grace_deadline != nil ->
              min(deadline - now, max(exit_grace_deadline - now, 0))

            true ->
              max(deadline - now, 0)
          end

        receive do
          {:stdout, ^os_pid, data} when is_binary(data) ->
            new_deadline =
              if exit_code != nil,
                do: System.monotonic_time(:millisecond) + @post_exit_grace_ms,
                else: exit_grace_deadline

            loop_collect(
              os_pid,
              [data | out_acc],
              err_acc,
              deadline,
              exit_code,
              timed_out,
              new_deadline
            )

          {:stderr, ^os_pid, data} when is_binary(data) ->
            new_deadline =
              if exit_code != nil,
                do: System.monotonic_time(:millisecond) + @post_exit_grace_ms,
                else: exit_grace_deadline

            loop_collect(
              os_pid,
              out_acc,
              [data | err_acc],
              deadline,
              exit_code,
              timed_out,
              new_deadline
            )

          {'DOWN', ^os_pid, _process, _pid, reason} ->
            code = reason_to_exit_code(reason)
            new_grace = System.monotonic_time(:millisecond) + @post_exit_grace_ms
            loop_collect(os_pid, out_acc, err_acc, deadline, code, timed_out, new_grace)
        after
          timeout ->
            {out_acc |> Enum.reverse() |> IO.iodata_to_binary(),
             err_acc |> Enum.reverse() |> IO.iodata_to_binary(), exit_code, timed_out}
        end
    end
  end

  defp reason_to_exit_code(:normal), do: 0
  defp reason_to_exit_code({:exit_status, status}) when is_integer(status), do: status
  defp reason_to_exit_code(_), do: -1

  defp maybe_infer_exit_code(nil, os_pid) when is_integer(os_pid) do
    case :exec.pid(os_pid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: nil, else: 0

      _ ->
        0
    end
  end

  defp maybe_infer_exit_code(exit_code, _os_pid), do: exit_code

  defp aggregate_output(stdout, stderr) do
    total_len = byte_size(stdout) + byte_size(stderr)

    if total_len <= @exec_output_max_bytes do
      stdout <> stderr
    else
      want_stdout = min(byte_size(stdout), div(@exec_output_max_bytes, 3))
      want_stderr = byte_size(stderr)
      stderr_take = min(want_stderr, @exec_output_max_bytes - want_stdout)
      remaining = @exec_output_max_bytes - want_stdout - stderr_take
      stdout_take = want_stdout + min(remaining, max(byte_size(stdout) - want_stdout, 0))

      stdout_part = if stdout_take > 0, do: binary_part(stdout, 0, stdout_take), else: ""
      stderr_part = if stderr_take > 0, do: binary_part(stderr, 0, stderr_take), else: ""

      stdout_part <> stderr_part
    end
  end

  defp format_structured(output, exit_code, duration_ms, timed_out, truncation_policy) do
    content = build_content_with_timeout(output, duration_ms, timed_out)
    formatted = Truncate.formatted_truncate_text(content, truncation_policy)
    duration_seconds = Float.round(duration_ms / 1000, 1)

    payload = %{
      output: formatted,
      metadata: %{
        exit_code: exit_code,
        duration_seconds: duration_seconds
      }
    }

    Jason.encode!(payload)
  end

  defp format_freeform(output, exit_code, duration_ms, timed_out, truncation_policy) do
    content = build_content_with_timeout(output, duration_ms, timed_out)
    total_lines = Truncate.line_count(content)
    formatted = Truncate.truncate_text(content, truncation_policy)

    lines = [
      "Exit code: #{exit_code}",
      "Wall time: #{Float.round(duration_ms / 1000, 1)} seconds"
    ]

    lines =
      if Truncate.line_count(formatted) != total_lines do
        lines ++ ["Total output lines: #{total_lines}"]
      else
        lines
      end

    Enum.join(lines ++ ["Output:", formatted], "\n")
  end

  defp build_content_with_timeout(output, duration_ms, timed_out) do
    if timed_out do
      "command timed out after #{duration_ms} milliseconds\n#{output}"
    else
      output
    end
  end
end
