defmodule EchsCore.Tools.Exec do
  @moduledoc """
  UnifiedExec-style session management using erlexec.

  Provides:
  - exec_command: Start a command in a session, return output or session ID
  - write_stdin: Write to an existing session's stdin
  """

  use GenServer

  require Logger

  alias EchsCore.Tools.ExecEnv
  alias EchsCore.Tools.HeadTailBuffer
  alias EchsCore.Tools.Truncate

  @default_yield_time_ms 10_000
  @default_write_stdin_yield_ms 250
  @default_max_output_tokens 10_000
  @min_yield_time_ms 250
  @min_empty_yield_time_ms 5_000
  @max_yield_time_ms 30_000
  @post_exit_grace_ms 50
  @max_output_bytes 1_048_576

  defstruct [
    :sessions,
    :os_pid_index,
    :next_id
  ]

  defmodule Session do
    @moduledoc false
    defstruct [
      :os_pid,
      :pid,
      :buffer,
      :exit_code,
      :started_at,
      :command,
      :cwd,
      :tty
    ]
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def exec_command(server \\ __MODULE__, opts) do
    GenServer.call(server, {:exec_command, opts}, :infinity)
  end

  def write_stdin(server \\ __MODULE__, opts) do
    GenServer.call(server, {:write_stdin, opts}, :infinity)
  end

  def kill_session(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:kill_session, session_id})
  end

  def list_sessions(server \\ __MODULE__) do
    GenServer.call(server, :list_sessions)
  end

  @doc """
  Kill all active sessions. Used during daemon startup to clean up leaked
  sessions from previous runs.
  """
  def kill_all_sessions(server \\ __MODULE__) do
    GenServer.call(server, :kill_all_sessions)
  end

  def exec_command_spec do
    %{
      "type" => "function",
      "name" => "exec_command",
      "description" =>
        "Runs a command in a PTY, returning output or a session ID for ongoing interaction.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "cmd" => %{
            "type" => "string",
            "description" => "Shell command to execute."
          },
          "workdir" => %{
            "type" => "string",
            "description" =>
              "Optional working directory to run the command in; defaults to the turn cwd."
          },
          "shell" => %{
            "type" => "string",
            "description" => "Shell binary to launch. Defaults to the user's default shell."
          },
          "login" => %{
            "type" => "boolean",
            "description" => "Whether to run the shell with -l/-i semantics. Defaults to true."
          },
          "tty" => %{
            "type" => "boolean",
            "description" =>
              "Whether to allocate a TTY for the command. Defaults to false (plain pipes); set to true to open a PTY and access TTY process."
          },
          "yield_time_ms" => %{
            "type" => "number",
            "description" => "How long to wait (in milliseconds) for output before yielding."
          },
          "max_output_tokens" => %{
            "type" => "number",
            "description" =>
              "Maximum number of tokens to return. Excess output will be truncated."
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
        "required" => ["cmd"],
        "additionalProperties" => false
      }
    }
  end

  def write_stdin_spec do
    %{
      "type" => "function",
      "name" => "write_stdin",
      "description" => "Writes characters to an existing exec session and returns recent output.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "session_id" => %{
            "type" => "number",
            "description" => "Identifier of the running unified exec session."
          },
          "chars" => %{
            "type" => "string",
            "description" => "Bytes to write to stdin (may be empty to poll)."
          },
          "yield_time_ms" => %{
            "type" => "number",
            "description" => "How long to wait (in milliseconds) for output before yielding."
          },
          "max_output_tokens" => %{
            "type" => "number",
            "description" =>
              "Maximum number of tokens to return. Excess output will be truncated."
          }
        },
        "required" => ["session_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def init(_opts) do
    ensure_exec_started()

    state = %__MODULE__{
      sessions: %{},
      os_pid_index: %{},
      next_id: 1000
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:exec_command, opts}, _from, state) do
    cmd = Keyword.fetch!(opts, :cmd)
    cwd = Keyword.get(opts, :cwd) || Keyword.get(opts, :workdir) || File.cwd!()
    shell = Keyword.get(opts, :shell, System.get_env("SHELL") || "/bin/bash")
    login = Keyword.get(opts, :login, true)
    tty = Keyword.get(opts, :tty, false)
    yield_time_ms = clamp_yield_time(Keyword.get(opts, :yield_time_ms, @default_yield_time_ms))
    max_tokens = resolve_max_tokens(Keyword.get(opts, :max_output_tokens))

    {session_id, state} = allocate_session_id(state)

    command = command_args(shell, cmd, login)
    env = ExecEnv.create_env() |> ExecEnv.apply_unified_exec_env()
    exec_opts = build_exec_opts(cwd, env, tty)

    start_time = System.monotonic_time(:millisecond)

    case :exec.run(command, exec_opts) do
      {:ok, pid, os_pid} ->
        session = %Session{
          os_pid: os_pid,
          pid: pid,
          buffer: HeadTailBuffer.new(@max_output_bytes),
          exit_code: nil,
          started_at: start_time,
          command: command,
          cwd: cwd,
          tty: tty
        }

        {output, exit_code, session} =
          collect_output(os_pid, session, yield_time_ms)

        wall_time = (System.monotonic_time(:millisecond) - start_time) / 1000
        {truncated_output, original_token_count} = truncate_output(output, max_tokens)
        chunk_id = generate_chunk_id()

        if exit_code != nil do
          result =
            format_exec_result(
              chunk_id: chunk_id,
              session_id: nil,
              exit_code: exit_code,
              wall_time: wall_time,
              output: truncated_output,
              original_token_count: original_token_count
            )

          {:reply, {:ok, result}, state}
        else
          state = %{
            state
            | sessions: Map.put(state.sessions, session_id, session),
              os_pid_index: Map.put(state.os_pid_index, os_pid, session_id)
          }

          result =
            format_exec_result(
              chunk_id: chunk_id,
              session_id: session_id,
              exit_code: nil,
              wall_time: wall_time,
              output: truncated_output,
              original_token_count: original_token_count
            )

          {:reply, {:ok, result}, state}
        end

      {:error, reason} ->
        {:reply, {:error, "exec_command failed: #{inspect(reason)}"}, state}
    end
  end

  @impl true
  def handle_call({:write_stdin, opts}, _from, state) do
    session_id = Keyword.fetch!(opts, :session_id) |> to_string()
    chars = Keyword.get(opts, :chars, "")
    yield_time_ms = Keyword.get(opts, :yield_time_ms, @default_write_stdin_yield_ms)

    yield_time_ms =
      if chars == "" do
        clamp_yield_time(max(yield_time_ms, @min_empty_yield_time_ms))
      else
        clamp_yield_time(yield_time_ms)
      end

    max_tokens = resolve_max_tokens(Keyword.get(opts, :max_output_tokens))

    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, "write_stdin failed: Unknown process id #{session_id}"}, state}

      session ->
        start_time = System.monotonic_time(:millisecond)

        if chars != "" and session.tty != true do
          {:reply,
           {:error,
            "write_stdin failed: stdin is closed for this session; rerun exec_command with tty=true to keep stdin open"},
           state}
        else
          if chars != "" do
            :ok = :exec.send(session.os_pid, chars)
            Process.sleep(100)
          end

          {output, exit_code, session} = collect_output(session.os_pid, session, yield_time_ms)
          wall_time = (System.monotonic_time(:millisecond) - start_time) / 1000

          {truncated_output, original_token_count} = truncate_output(output, max_tokens)
          chunk_id = generate_chunk_id()

          if exit_code != nil do
            state = remove_session(state, session_id, session.os_pid)

            result =
              format_write_stdin_result(
                chunk_id: chunk_id,
                session_id: nil,
                exit_code: exit_code,
                wall_time: wall_time,
                output: truncated_output,
                original_token_count: original_token_count
              )

            {:reply, {:ok, result}, state}
          else
            state = %{state | sessions: Map.put(state.sessions, session_id, session)}

            result =
              format_write_stdin_result(
                chunk_id: chunk_id,
                session_id: session_id,
                exit_code: nil,
                wall_time: wall_time,
                output: truncated_output,
                original_token_count: original_token_count
              )

            {:reply, {:ok, result}, state}
          end
        end
    end
  end

  @impl true
  def handle_call({:kill_session, session_id}, _from, state) do
    session_id = to_string(session_id)

    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, "Session not found"}, state}

      session ->
        if is_integer(session.os_pid) do
          :exec.stop(session.os_pid)
        end

        state = remove_session(state, session_id, session.os_pid)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:kill_all_sessions, _from, state) do
    Enum.each(state.sessions, fn {_id, session} ->
      if is_integer(session.os_pid) do
        try do
          :exec.stop(session.os_pid)
        catch
          _, _ -> :ok
        end
      end
    end)

    state = %{state | sessions: %{}, os_pid_to_session: %{}}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions =
      for {id, session} <- state.sessions do
        %{
          session_id: id,
          command: session.command,
          cwd: session.cwd,
          started_at: session.started_at,
          exit_code: session.exit_code,
          buffered_bytes: HeadTailBuffer.retained_bytes(session.buffer)
        }
      end

    {:reply, sessions, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, state) do
    handle_output(os_pid, data, state)
  end

  @impl true
  def handle_info({:stderr, os_pid, data}, state) do
    handle_output(os_pid, data, state)
  end

  @impl true
  def handle_info({:DOWN, os_pid, _process, _pid, reason}, state) when is_integer(os_pid) do
    case Map.get(state.os_pid_index, os_pid) do
      nil ->
        {:noreply, state}

      session_id ->
        case Map.get(state.sessions, session_id) do
          nil ->
            {:noreply, state}

          session ->
            exit_code = reason_to_exit_code(reason)
            session = %{session | exit_code: exit_code}
            state = %{state | sessions: Map.put(state.sessions, session_id, session)}
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def command_args(shell, cmd, login) do
    shell = shell || System.get_env("SHELL") || "/bin/bash"
    shell_type = classify_shell_name(shell)

    cond do
      shell_type in ["bash", "zsh", "sh"] ->
        arg = if login, do: "-lc", else: "-c"
        [shell, arg, cmd]

      shell_type in ["powershell", "pwsh"] ->
        base = [shell]
        base = if login, do: base, else: base ++ ["-NoProfile"]
        base ++ ["-Command", cmd]

      shell_type == "cmd" ->
        [shell, "/c", cmd]

      true ->
        arg = if login, do: "-lc", else: "-c"
        [shell, arg, cmd]
    end
  end

  defp classify_shell_name(shell) do
    shell
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
  end

  defp ensure_exec_started do
    case Application.ensure_all_started(:erlexec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Logger.error("failed to start erlexec: #{inspect(reason)}")
    end
  end

  defp build_exec_opts(cwd, env, tty) do
    env_list = Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)

    base = [:monitor, :stdout, :stderr, {:cd, cwd}, {:env, env_list}]

    if tty do
      [:pty, :stdin | base]
    else
      base
    end
  end

  defp handle_output(os_pid, data, state) when is_binary(data) do
    case Map.get(state.os_pid_index, os_pid) do
      nil ->
        {:noreply, state}

      session_id ->
        case Map.get(state.sessions, session_id) do
          nil ->
            {:noreply, state}

          session ->
            buffer = HeadTailBuffer.push_chunk(session.buffer, data)
            session = %{session | buffer: buffer}
            state = %{state | sessions: Map.put(state.sessions, session_id, session)}
            {:noreply, state}
        end
    end
  end

  defp handle_output(_os_pid, _data, state), do: {:noreply, state}

  defp collect_output(os_pid, session, yield_time_ms) do
    deadline = System.monotonic_time(:millisecond) + yield_time_ms

    {chunks, buffer} = HeadTailBuffer.drain_chunks(session.buffer)
    acc = Enum.reverse(chunks)

    exit_code = session.exit_code
    exit_code = maybe_infer_exit_code(exit_code, os_pid)
    exit_seen = not is_nil(exit_code)
    exit_grace_deadline =
      if exit_seen, do: System.monotonic_time(:millisecond) + @post_exit_grace_ms, else: nil

    {acc, exit_code} =
      collect_output_loop(
        os_pid,
        acc,
        deadline,
        exit_code,
        exit_seen,
        exit_grace_deadline
      )

    output = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {output, exit_code, %{session | buffer: buffer, exit_code: exit_code}}
  end

  defp collect_output_loop(os_pid, acc, deadline, exit_code, exit_seen, exit_grace_deadline) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline - now

    cond do
      remaining <= 0 ->
        {acc, exit_code}

      exit_seen and exit_grace_deadline != nil and now >= exit_grace_deadline ->
        {acc, exit_code}

      true ->
        {exit_code, exit_seen, exit_grace_deadline} =
          if exit_code == nil do
            case maybe_infer_exit_code(nil, os_pid) do
              nil ->
                {exit_code, exit_seen, exit_grace_deadline}

              inferred ->
                {inferred, true, System.monotonic_time(:millisecond) + @post_exit_grace_ms}
            end
          else
            {exit_code, exit_seen, exit_grace_deadline}
          end

        timeout =
          if exit_seen and exit_grace_deadline != nil do
            min(remaining, max(exit_grace_deadline - now, 0))
          else
            remaining
          end

        receive do
          {:stdout, ^os_pid, data} when is_binary(data) ->
            new_acc = [data | acc]
            new_deadline = if exit_seen, do: System.monotonic_time(:millisecond) + @post_exit_grace_ms, else: exit_grace_deadline
            collect_output_loop(os_pid, new_acc, deadline, exit_code, exit_seen, new_deadline)

          {:stderr, ^os_pid, data} when is_binary(data) ->
            new_acc = [data | acc]
            new_deadline = if exit_seen, do: System.monotonic_time(:millisecond) + @post_exit_grace_ms, else: exit_grace_deadline
            collect_output_loop(os_pid, new_acc, deadline, exit_code, exit_seen, new_deadline)

          {:DOWN, ^os_pid, _process, _pid, reason} ->
            code = reason_to_exit_code(reason)
            new_deadline = System.monotonic_time(:millisecond) + @post_exit_grace_ms
            collect_output_loop(os_pid, acc, deadline, code, true, new_deadline)
        after
          timeout ->
            {acc, exit_code}
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

  defp remove_session(state, session_id, os_pid) do
    os_pid_index =
      if is_integer(os_pid) do
        Map.delete(state.os_pid_index, os_pid)
      else
        state.os_pid_index
      end

    %{state | sessions: Map.delete(state.sessions, session_id), os_pid_index: os_pid_index}
  end

  defp allocate_session_id(state) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    {to_string(id), state}
  end

  defp truncate_output(output, max_tokens) do
    formatted = Truncate.formatted_truncate_text(output, {:tokens, max_tokens})
    {formatted, Truncate.approx_token_count(output)}
  end

  defp format_exec_result(opts) do
    chunk_id = Keyword.get(opts, :chunk_id, "")
    session_id = Keyword.get(opts, :session_id)
    exit_code = Keyword.get(opts, :exit_code)
    wall_time = Keyword.get(opts, :wall_time)
    output = Keyword.get(opts, :output)
    original_token_count = Keyword.get(opts, :original_token_count)

    lines = []

    lines =
      if chunk_id != "" do
        lines ++ ["Chunk ID: #{chunk_id}"]
      else
        lines
      end

    lines = lines ++ ["Wall time: #{format_wall_time(wall_time)} seconds"]

    lines =
      if exit_code != nil do
        lines ++ ["Process exited with code #{exit_code}"]
      else
        lines
      end

    lines =
      if session_id != nil do
        lines ++ ["Process running with session ID #{session_id}"]
      else
        lines
      end

    lines =
      if original_token_count != nil do
        lines ++ ["Original token count: #{original_token_count}"]
      else
        lines
      end

    lines = lines ++ ["Output:", output]

    Enum.join(lines, "\n")
  end

  defp format_write_stdin_result(opts) do
    chunk_id = Keyword.get(opts, :chunk_id, "")
    session_id = Keyword.get(opts, :session_id)
    exit_code = Keyword.get(opts, :exit_code)
    wall_time = Keyword.get(opts, :wall_time)
    output = Keyword.get(opts, :output)
    original_token_count = Keyword.get(opts, :original_token_count)

    lines = []

    lines =
      if chunk_id != "" do
        lines ++ ["Chunk ID: #{chunk_id}"]
      else
        lines
      end

    lines = lines ++ ["Wall time: #{format_wall_time(wall_time)} seconds"]

    lines =
      if exit_code != nil do
        lines ++ ["Process exited with code #{exit_code}"]
      else
        lines
      end

    lines =
      if session_id != nil do
        lines ++ ["Process running with session ID #{session_id}"]
      else
        lines
      end

    lines =
      if original_token_count != nil do
        lines ++ ["Original token count: #{original_token_count}"]
      else
        lines
      end

    lines = lines ++ ["Output:", output]

    Enum.join(lines, "\n")
  end

  defp format_wall_time(wall_time) do
    wall_time |> :erlang.float_to_binary(decimals: 4)
  end

  defp generate_chunk_id do
    1..6
    |> Enum.map(fn _ -> :rand.uniform(16) - 1 end)
    |> Enum.map_join(fn n -> Integer.to_string(n, 16) end)
  end

  defp resolve_max_tokens(nil), do: @default_max_output_tokens
  defp resolve_max_tokens(tokens) when is_integer(tokens), do: tokens
  defp resolve_max_tokens(_), do: @default_max_output_tokens

  defp clamp_yield_time(yield_time_ms) when is_integer(yield_time_ms) do
    yield_time_ms |> max(@min_yield_time_ms) |> min(@max_yield_time_ms)
  end

  defp clamp_yield_time(_), do: @default_yield_time_ms
end
