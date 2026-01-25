defmodule EchsCore.Tools.Exec do
  @moduledoc """
  UnifiedExec-style session management using `Port`s.

  Provides:
  - exec_command: Start a command in a session, return output or session ID
  - write_stdin: Write to an existing session's stdin

  Note: this is not a full pseudo-terminal (TTY). Programs that require a real
  terminal (e.g. full-screen TUIs) may not behave as expected.
  """

  use GenServer

  @default_yield_time_ms 10_000
  @default_write_stdin_yield_ms 250
  @max_buffer_bytes 200_000

  defstruct [
    # %{session_id => session_state}
    :sessions,
    # %{port => session_id}
    :port_index,
    # Counter for deterministic IDs in test mode
    :next_id
  ]

  defmodule Session do
    @moduledoc false
    defstruct [
      :port,
      :buffer,
      :exit_code,
      :started_at,
      :command,
      :cwd
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Execute a command in a PTY session.
  Returns output and optionally a session_id if the process is still running.
  """
  def exec_command(server \\ __MODULE__, opts) do
    GenServer.call(server, {:exec_command, opts}, :infinity)
  end

  @doc """
  Write to an existing session's stdin and get output.
  """
  def write_stdin(server \\ __MODULE__, opts) do
    GenServer.call(server, {:write_stdin, opts}, :infinity)
  end

  @doc """
  Kill a session.
  """
  def kill_session(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:kill_session, session_id})
  end

  @doc """
  List active sessions.
  """
  def list_sessions(server \\ __MODULE__) do
    GenServer.call(server, :list_sessions)
  end

  # Tool specs

  def exec_command_spec do
    %{
      "type" => "function",
      "name" => "exec_command",
      "description" =>
        "Runs a command in a session, returning output or a session ID for ongoing interaction.",
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
            "description" => "Shell binary to launch. Defaults to /bin/bash."
          },
          "login" => %{
            "type" => "boolean",
            "description" => "Whether to run the shell with -l/-i semantics. Defaults to true."
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

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      sessions: %{},
      port_index: %{},
      next_id: 1000
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:exec_command, opts}, _from, state) do
    cmd = Keyword.fetch!(opts, :cmd)
    cwd = Keyword.get(opts, :cwd) || Keyword.get(opts, :workdir) || File.cwd!()
    shell = Keyword.get(opts, :shell, "/bin/bash")
    login = Keyword.get(opts, :login, true)
    yield_time_ms = Keyword.get(opts, :yield_time_ms, @default_yield_time_ms)
    max_tokens = Keyword.get(opts, :max_output_tokens, 10_000)

    # Allocate session ID
    {session_id, state} = allocate_session_id(state)

    # Build the command
    command = build_command(shell, cmd, login)

    # Start the PTY port
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:cd, cwd},
      {:env, pty_env()},
      {:args, tl(command)}
    ]

    start_time = System.monotonic_time(:millisecond)

    port =
      try do
        Port.open({:spawn_executable, hd(command)}, port_opts)
      rescue
        e ->
          {:error, Exception.message(e)}
      end

    case port do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      port when is_port(port) ->
        # Collect output for yield_time_ms
        {output, exit_code} = collect_output(port, yield_time_ms)
        wall_time = (System.monotonic_time(:millisecond) - start_time) / 1000

        # Truncate output
        truncated_output = truncate_output(output, max_tokens)

        if exit_code != nil do
          # Process completed
          safe_close_port(port)

          result =
            format_exec_result(
              session_id: nil,
              exit_code: exit_code,
              wall_time: wall_time,
              output: truncated_output
            )

          {:reply, {:ok, result}, state}
        else
          # Process still running - store session
          session = %Session{
            port: port,
            buffer: "",
            exit_code: nil,
            started_at: start_time,
            command: command,
            cwd: cwd
          }

          state = %{
            state
            | sessions: Map.put(state.sessions, session_id, session),
              port_index: Map.put(state.port_index, port, session_id)
          }

          result =
            format_exec_result(
              session_id: session_id,
              exit_code: nil,
              wall_time: wall_time,
              output: truncated_output
            )

          {:reply, {:ok, result}, state}
        end
    end
  end

  @impl true
  def handle_call({:write_stdin, opts}, _from, state) do
    session_id = Keyword.fetch!(opts, :session_id) |> to_string()
    chars = Keyword.get(opts, :chars, "")
    yield_time_ms = Keyword.get(opts, :yield_time_ms, @default_write_stdin_yield_ms)
    max_tokens = Keyword.get(opts, :max_output_tokens, 10_000)

    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, "Session #{session_id} not found"}, state}

      session ->
        start_time = System.monotonic_time(:millisecond)

        buffered = session.buffer || ""

        # Write to stdin if chars provided
        if chars != "" and is_port(session.port) do
          Port.command(session.port, chars)
        end

        # Collect output (if the process is still alive)
        {output, exit_code} =
          if is_port(session.port) do
            collect_output(session.port, yield_time_ms)
          else
            {"", session.exit_code}
          end

        wall_time = (System.monotonic_time(:millisecond) - start_time) / 1000

        truncated_output = truncate_output(buffered <> output, max_tokens)

        if exit_code != nil do
          # Process exited - remove session
          if is_port(session.port) do
            safe_close_port(session.port)
          end

          state = remove_session(state, session_id, session.port)

          result =
            format_write_stdin_result(
              session_id: nil,
              exit_code: exit_code,
              wall_time: wall_time,
              output: truncated_output
            )

          {:reply, {:ok, result}, state}
        else
          # Clear the buffer since we just returned it.
          session = %{session | buffer: ""}
          state = %{state | sessions: Map.put(state.sessions, session_id, session)}

          result =
            format_write_stdin_result(
              session_id: session_id,
              exit_code: nil,
              wall_time: wall_time,
              output: truncated_output
            )

          {:reply, {:ok, result}, state}
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
        if is_port(session.port) do
          safe_close_port(session.port)
        end

        state = remove_session(state, session_id, session.port)
        {:reply, :ok, state}
    end
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
          buffered_bytes: byte_size(session.buffer || "")
        }
      end

    {:reply, sessions, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Map.get(state.port_index, port) do
      nil ->
        {:noreply, state}

      session_id ->
        case Map.get(state.sessions, session_id) do
          nil ->
            {:noreply, %{state | port_index: Map.delete(state.port_index, port)}}

          session ->
            # Mark exited; keep buffered output so it can be retrieved on the next
            # `write_stdin` call.
            safe_close_port(port)

            session = %{session | exit_code: status, port: nil}

            state = %{
              state
              | sessions: Map.put(state.sessions, session_id, session),
                port_index: Map.delete(state.port_index, port)
            }

            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case Map.get(state.port_index, port) do
      nil ->
        {:noreply, state}

      session_id ->
        case Map.get(state.sessions, session_id) do
          nil ->
            {:noreply, state}

          session ->
            buffer = (session.buffer || "") <> data
            buffer = truncate_buffer(buffer)
            session = %{session | buffer: buffer}
            state = %{state | sessions: Map.put(state.sessions, session_id, session)}
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp remove_session(state, session_id, port) do
    port_index =
      if is_port(port) do
        Map.delete(state.port_index, port)
      else
        state.port_index
      end

    %{state | sessions: Map.delete(state.sessions, session_id), port_index: port_index}
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp allocate_session_id(state) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    {to_string(id), state}
  end

  defp build_command(shell, cmd, login) do
    if login do
      [shell, "-l", "-c", cmd]
    else
      [shell, "-c", cmd]
    end
  end

  defp pty_env do
    [
      {~c"NO_COLOR", ~c"1"},
      {~c"TERM", ~c"dumb"},
      {~c"LANG", ~c"C.UTF-8"},
      {~c"LC_CTYPE", ~c"C.UTF-8"},
      {~c"LC_ALL", ~c"C.UTF-8"},
      {~c"COLORTERM", ~c""},
      {~c"PAGER", ~c"cat"},
      {~c"GIT_PAGER", ~c"cat"}
    ]
  end

  defp collect_output(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_output_loop(port, deadline, [])
  end

  defp collect_output_loop(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout reached, return what we have
      {IO.iodata_to_binary(Enum.reverse(acc)), nil}
    else
      receive do
        {^port, {:data, data}} ->
          collect_output_loop(port, deadline, [data | acc])

        {^port, {:exit_status, status}} ->
          # Process exited
          {IO.iodata_to_binary(Enum.reverse(acc)), status}
      after
        min(remaining, 100) ->
          # Check if port is still alive
          if Port.info(port) == nil do
            {IO.iodata_to_binary(Enum.reverse(acc)), 0}
          else
            collect_output_loop(port, deadline, acc)
          end
      end
    end
  end

  defp truncate_output(output, max_tokens) do
    # Rough estimate: 4 chars per token
    max_chars = max_tokens * 4

    if String.length(output) > max_chars do
      String.slice(output, 0, max_chars) <> "\n... [truncated]"
    else
      output
    end
  end

  defp truncate_buffer(buffer) when is_binary(buffer) do
    if byte_size(buffer) <= @max_buffer_bytes do
      buffer
    else
      keep = @max_buffer_bytes
      start = byte_size(buffer) - keep
      "[buffer truncated]\n" <> binary_part(buffer, start, keep)
    end
  end

  defp format_exec_result(opts) do
    session_id = Keyword.get(opts, :session_id)
    exit_code = Keyword.get(opts, :exit_code)
    wall_time = Keyword.get(opts, :wall_time)
    output = Keyword.get(opts, :output)

    lines = []

    lines = lines ++ ["Wall time: #{Float.round(wall_time, 4)} seconds"]

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

    lines = lines ++ ["Output:", output]

    Enum.join(lines, "\n")
  end

  defp format_write_stdin_result(opts) do
    session_id = Keyword.get(opts, :session_id)
    exit_code = Keyword.get(opts, :exit_code)
    wall_time = Keyword.get(opts, :wall_time)
    output = Keyword.get(opts, :output)

    lines = ["Wall time: #{Float.round(wall_time, 4)} seconds"]

    lines =
      if exit_code != nil do
        lines ++ ["Process exited with code #{exit_code}"]
      else
        lines
      end

    lines =
      if session_id != nil do
        lines ++ ["Session ID #{session_id} still running"]
      else
        lines
      end

    lines = lines ++ ["Output:", output]

    Enum.join(lines, "\n")
  end
end
