defmodule EchsCore.ThreadWorker.ToolDispatch do
  @moduledoc """
  Tool execution, dispatch, and coordination for ThreadWorker.

  Handles tool call execution, sub-agent management, blackboard operations,
  custom tool invocation, and all tool-related helpers.
  """

  require Logger

  alias EchsCore.{Tools, Blackboard, ModelInfo}
  alias EchsCore.ThreadWorker.Config, as: TWConfig
  alias EchsCore.ThreadWorker.HistoryManager, as: TWHistory

  @soft_subagent_limit 10
  @hard_subagent_limit 20

  @parallel_safe_tools MapSet.new([
    "shell", "shell_command", "exec_command",
    "read_file", "list_dir", "grep_files",
    "blackboard_read", "view_image"
  ])

  # -------------------------------------------------------------------
  # Main entry point
  # -------------------------------------------------------------------

  def execute_tool_calls(state, tool_calls) do
    groups = group_tool_calls(tool_calls)

    Enum.flat_map_reduce(groups, state, fn group, acc_state ->
      {calls, is_parallel} = unzip_group(group)

      if is_parallel and length(calls) > 1 do
        execute_parallel_group(acc_state, calls)
      else
        execute_sequential_group(acc_state, calls)
      end
    end)
  end

  defp unzip_group(group) do
    calls = Enum.map(group, &elem(&1, 0))
    is_parallel = match?([{_, true} | _], group)
    {calls, is_parallel}
  end

  defp parallel_safe?(item) do
    case item["type"] do
      "local_shell_call" -> true
      type when type in ["function_call", "custom_tool_call"] ->
        name = item["name"] || ""
        MapSet.member?(@parallel_safe_tools, name) or String.starts_with?(name, "forum_")
      _ -> false
    end
  end

  defp group_tool_calls(tool_calls) do
    Enum.chunk_while(
      tool_calls,
      [],
      fn call, acc ->
        is_par = parallel_safe?(call)
        case acc do
          [] -> {:cont, [{call, is_par}]}
          [{_, true} | _] when is_par -> {:cont, [{call, is_par} | acc]}
          _ -> {:cont, Enum.reverse(acc), [{call, is_par}]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp execute_parallel_group(state, calls) do
    tasks =
      Enum.map(calls, fn call ->
        Task.async(fn ->
          try do
            execute_tool_call(state, call)
          rescue
            e -> {{:error, "#{tool_label(call)} crashed: #{Exception.message(e)}"}, state}
          catch
            kind, reason -> {{:error, "#{tool_label(call)} #{kind}: #{inspect(reason)}"}, state}
          end
        end)
      end)

    timeout = max_tool_timeout_ms() + 5_000

    results =
      Task.yield_many(tasks, timeout: timeout)
      |> Enum.zip(calls)
      |> Enum.map(fn {{task, outcome}, call} ->
        {result, _returned_state} =
          case outcome do
            {:ok, {result, rstate}} -> {result, rstate}
            {:exit, reason} -> {{:error, "#{tool_label(call)} crashed: #{inspect(reason)}"}, state}
            nil ->
              Task.shutdown(task, :brutal_kill)
              {{:error, "#{tool_label(call)} timed out"}, state}
          end
        build_tool_output(state, call, result)
      end)

    # Parallel tools don't modify state
    {results, state}
  end

  defp execute_sequential_group(state, calls) do
    Enum.map_reduce(calls, state, fn call, acc_state ->
      {result, next_state} = execute_tool_call(acc_state, call)
      {build_tool_output(acc_state, call, result), next_state}
    end)
  end

  defp build_tool_output(state, call, result) do
    call_id = call["call_id"] || call["id"]

    output_type =
      case call["type"] do
        "custom_tool_call" -> "custom_tool_call_output"
        _ -> "function_call_output"
      end

    formatted = format_tool_result(result)

    broadcast(state, :tool_completed, %{
      thread_id: state.thread_id,
      call_id: call_id,
      result: formatted
    })

    %{"type" => output_type, "call_id" => call_id, "output" => formatted}
  end

  # -------------------------------------------------------------------
  # Result formatting
  # -------------------------------------------------------------------

  def format_tool_result(result) when is_binary(result), do: sanitize_binary(result)
  def format_tool_result({:ok, data}) when is_binary(data), do: sanitize_binary(data)

  def format_tool_result({:ok, data}) do
    try do
      Jason.encode!(data)
    rescue
      Jason.EncodeError ->
        # Data contains invalid bytes (e.g., binary file content)
        inspect(data, limit: 5000, printable_limit: 5000)
    end
  end

  def format_tool_result({:error, err}) when is_binary(err), do: err
  def format_tool_result({:error, err}), do: "Error: #{inspect(err)}"
  def format_tool_result(:ok), do: "OK"
  def format_tool_result(other), do: inspect(other)

  # Sanitize binary data to ensure valid UTF-8 for JSON encoding
  def sanitize_binary(data) do
    if String.valid?(data) do
      data
    else
      # Replace invalid bytes with replacement character
      data
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _rest} -> valid <> " [binary data truncated]"
        {:incomplete, valid, _rest} -> valid <> " [binary data truncated]"
        valid when is_binary(valid) -> valid
      end
    end
  end

  # -------------------------------------------------------------------
  # Single tool call execution
  # -------------------------------------------------------------------

  def execute_tool_call(state, item) do
    start_ms = System.monotonic_time(:millisecond)
    call_id = item["call_id"] || item["id"] || ""
    tool_name = item["name"] || item["type"] || "unknown"
    EchsCore.Telemetry.tool_start(state.thread_id, tool_name, call_id)
    log_tool_event(:start, item)

    result =
      try do
        case item["type"] do
          "local_shell_call" ->
            command = get_in(item, ["action", "command"]) || []
            cwd = get_in(item, ["action", "working_directory"]) || state.cwd
            timeout_ms = (get_in(item, ["action", "timeout_ms"]) || tool_timeout_ms()) |> clamp_tool_timeout()

            case command do
              [_ | _] ->
                result =
                  run_tool_with_timeout(
                    fn -> Tools.Shell.execute_array(command, cwd: cwd, timeout_ms: timeout_ms) end,
                    timeout_ms,
                    "local_shell_call"
                  )

                {result, state}

              [] ->
                {{:error, "unsupported payload for shell handler: local_shell"}, state}
            end

          "function_call" ->
            name = item["name"]

            case decode_tool_args(item["arguments"]) do
              {:ok, args} ->
                timeout_ms =
                  args
                  |> Map.get("timeout_ms", tool_timeout_ms())
                  |> clamp_tool_timeout()
                  |> maybe_pad_tool_timeout_ms(name)

                run_tool_with_timeout(
                  fn -> execute_named_tool(state, name, args) end,
                  timeout_ms,
                  "tool #{name}"
                )
                |> unwrap_tool_result(state)

              {:error, reason} ->
                if name == "apply_patch" and is_binary(item["arguments"]) do
                  args = %{"input" => item["arguments"]}
                  timeout_ms =
                    args
                    |> Map.get("timeout_ms", tool_timeout_ms())
                    |> clamp_tool_timeout()
                    |> maybe_pad_tool_timeout_ms(name)

                  run_tool_with_timeout(
                    fn -> execute_named_tool(state, name, args) end,
                    timeout_ms,
                    "tool #{name}"
                  )
                  |> unwrap_tool_result(state)
                else
                  {{:error, reason}, state}
                end
            end

          "custom_tool_call" ->
            name = item["name"]
            input = item["input"] || item["arguments"]

            if name == "apply_patch" and is_binary(input) do
              args = %{"input" => input}
              timeout_ms =
                args
                |> Map.get("timeout_ms", tool_timeout_ms())
                |> clamp_tool_timeout()
                |> maybe_pad_tool_timeout_ms(name)

              run_tool_with_timeout(
                fn -> execute_named_tool(state, name, args) end,
                timeout_ms,
                "tool #{name}"
              )
              |> unwrap_tool_result(state)
            else
              {{:error, "unsupported custom tool call: #{name}"}, state}
            end

          _ ->
            {{:error, "Unknown item type: #{item["type"]}"}, state}
        end
      rescue
        e ->
          {{:error, "#{tool_label(item)} crashed: #{Exception.message(e)}"}, state}
      catch
        kind, reason ->
          {{:error, "#{tool_label(item)} #{kind}: #{inspect(reason)}"}, state}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_ms
    EchsCore.Telemetry.tool_stop(state.thread_id, tool_name, call_id, duration_ms)
    log_tool_event(:done, item, result, duration_ms)
    result
  end

  # -------------------------------------------------------------------
  # Tool label helpers
  # -------------------------------------------------------------------

  def tool_label(%{"type" => "function_call", "name" => name}) when is_binary(name),
    do: "tool #{name}"

  def tool_label(%{"type" => "custom_tool_call", "name" => name}) when is_binary(name),
    do: "tool #{name}"

  def tool_label(%{"type" => "local_shell_call"}), do: "local_shell_call"
  def tool_label(_), do: "tool"

  # -------------------------------------------------------------------
  # Argument decoding
  # -------------------------------------------------------------------

  def decode_tool_args(nil), do: {:ok, %{}}
  def decode_tool_args(args) when is_map(args), do: {:ok, args}

  def decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, "Invalid tool arguments: #{Exception.message(error)}"}
    end
  end

  def decode_tool_args(_), do: {:ok, %{}}

  # -------------------------------------------------------------------
  # Named tool dispatch
  # -------------------------------------------------------------------

  def execute_named_tool(state, name, args) do
    case name do
      "shell" ->
        cwd = args["workdir"] || state.cwd
        timeout_ms = args["timeout_ms"] || tool_timeout_ms()
        command = args["command"] || []

        case maybe_intercept_apply_patch(state, "shell", command, cwd) do
          :not_apply_patch ->
            truncation_policy = ModelInfo.truncation_policy(state.model)

            result =
              run_tool_with_timeout(
                fn ->
                  Tools.Shell.execute_array(command,
                    cwd: cwd,
                    timeout_ms: timeout_ms,
                    truncation_policy: truncation_policy
                  )
                end,
                timeout_ms,
                "shell"
              )

            {result, state}

          {:error, reason} ->
            {{:error, reason}, state}

          other ->
            {other, state}
        end

      "shell_command" ->
        cwd = args["workdir"] || state.cwd
        timeout_ms = args["timeout_ms"] || tool_timeout_ms()
        login = Map.get(args, "login", true)

        command = args["command"] || ""
        shell = state.shell_path || System.get_env("SHELL") || "/bin/bash"
        argv = Tools.Exec.command_args(shell, command, login)

        case maybe_intercept_apply_patch(state, "shell_command", argv, cwd) do
          :not_apply_patch ->
            result =
              Tools.Shell.execute_command(command,
                cwd: cwd,
                timeout_ms: timeout_ms,
                login: login,
                shell: shell,
                snapshot_path: state.shell_snapshot_path,
                truncation_policy: ModelInfo.truncation_policy(state.model)
              )

            {result, state}

          {:error, reason} ->
            {{:error, reason}, state}

          other ->
            {other, state}
        end

      "exec_command" ->
        {exec_command(state, args), state}

      "write_stdin" ->
        {write_stdin(state, args), state}

      "read_file" ->
        {Tools.Files.read_file(args["file_path"], args), state}

      "list_dir" ->
        {Tools.Files.list_dir(args["dir_path"], args), state}

      "grep_files" ->
        {Tools.Files.grep_files(args["pattern"], Map.put(args, "cwd", state.cwd)), state}

      "apply_patch" ->
        input = args["input"] || args["patch"] || ""
        {Tools.ApplyPatch.apply(input, cwd: state.cwd), state}

      "view_image" ->
        attach_image(state, args)

      "spawn_agent" ->
        spawn_subagent(state, args)

      "send_input" ->
        {send_to_subagent(state, args), state}

      "wait" ->
        {wait_for_agents(state, args), state}

      "blackboard_write" ->
        {blackboard_write(state, args), state}

      "blackboard_read" ->
        {blackboard_read(state, args), state}

      "close_agent" ->
        kill_subagent(state, args)

      name when is_binary(name) ->
        if String.starts_with?(name, "forum_") do
          {Tools.CodexForum.execute(name, args), state}
        else
          execute_custom_tool(state, name, args)
        end

      _ ->
        execute_custom_tool(state, name, args)
    end
  end

  # -------------------------------------------------------------------
  # Timeout wrapper
  # -------------------------------------------------------------------

  def run_tool_with_timeout(fun, timeout_ms, label) when is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, "#{label} crashed: #{inspect(reason)}"}

      nil ->
        {:error, "#{label} timed out after #{timeout_ms}ms"}
    end
  end

  def unwrap_tool_result({result, %EchsCore.ThreadWorker{} = state}, _fallback_state),
    do: {result, state}

  def unwrap_tool_result({result, state}, _fallback_state) when is_map(state),
    do: {result, state}

  def unwrap_tool_result(result, fallback_state), do: {result, fallback_state}

  # -------------------------------------------------------------------
  # Tool timeouts
  # -------------------------------------------------------------------

  @default_tool_timeout_ms 120_000
  @default_max_tool_timeout_ms 30 * 60 * 1000

  def tool_timeout_ms do
    env_int("ECHS_TOOL_TIMEOUT_MS", @default_tool_timeout_ms)
  end

  def max_tool_timeout_ms do
    env_int("ECHS_MAX_TOOL_TIMEOUT_MS", @default_max_tool_timeout_ms)
  end

  @doc """
  Clamp a requested timeout to [1, max_tool_timeout_ms].
  Called after extracting timeout_ms from tool args.
  """
  def clamp_tool_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    min(timeout_ms, max_tool_timeout_ms())
  end

  def clamp_tool_timeout(_), do: tool_timeout_ms()

  def maybe_pad_tool_timeout_ms(timeout_ms, name) when is_integer(timeout_ms) do
    case name do
      "shell" -> timeout_ms + tool_timeout_padding_ms()
      "shell_command" -> timeout_ms + tool_timeout_padding_ms()
      _ -> timeout_ms
    end
  end

  def maybe_pad_tool_timeout_ms(timeout_ms, _name), do: timeout_ms

  def tool_timeout_padding_ms do
    env_int("ECHS_TOOL_TIMEOUT_PADDING_MS", 2_000, allow_zero: true)
  end

  defp env_int(var, default, opts \\ []) do
    allow_zero = Keyword.get(opts, :allow_zero, false)

    case System.get_env(var) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          {0, _} when allow_zero -> 0
          _ -> default
        end
    end
  end

  # -------------------------------------------------------------------
  # Tool logging
  # -------------------------------------------------------------------

  def log_tool_event(:start, item) do
    if tool_log_enabled?() do
      Logger.info("tool.start #{summarize_tool_item(item)}")
    end
  end

  def log_tool_event(_stage, _item), do: :ok

  def log_tool_event(:done, item, {result, _state_after}, duration_ms) do
    if tool_log_enabled?() do
      Logger.info(
        "tool.done #{summarize_tool_item(item)} duration_ms=#{duration_ms} result=#{summarize_tool_result(result)}"
      )
    end
  end

  def log_tool_event(_stage, _item, _result, _duration_ms), do: :ok

  def tool_log_enabled? do
    System.get_env("ECHS_TOOL_LOG") in ["1", "true", "yes", "on"]
  end

  def summarize_tool_item(%{"type" => "function_call"} = item) do
    name = item["name"] || "unknown"
    call_id = item["call_id"] || item["id"] || ""
    "name=#{name} call_id=#{call_id}"
  end

  def summarize_tool_item(%{"type" => "custom_tool_call"} = item) do
    name = item["name"] || "unknown"
    call_id = item["call_id"] || item["id"] || ""
    "custom=#{name} call_id=#{call_id}"
  end

  def summarize_tool_item(%{"type" => "local_shell_call"} = item) do
    call_id = item["call_id"] || item["id"] || ""
    "local_shell call_id=#{call_id}"
  end

  def summarize_tool_item(item) when is_map(item) do
    "type=#{item["type"] || "unknown"}"
  end

  def summarize_tool_item(_), do: "unknown"

  def summarize_tool_result({:error, reason}) when is_binary(reason) do
    "error=#{truncate_event_text(reason)}"
  end

  def summarize_tool_result({:error, reason}), do: "error=#{inspect(reason)}"
  def summarize_tool_result(result) when is_binary(result), do: truncate_event_text(result)
  def summarize_tool_result(result), do: truncate_event_text(inspect(result))

  # -------------------------------------------------------------------
  # Text truncation (shared utility)
  # -------------------------------------------------------------------

  def truncate_event_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.length(trimmed) > 120 do
      String.slice(trimmed, 0, 120) <> "..."
    else
      trimmed
    end
  end

  def truncate_event_text(_), do: ""

  # -------------------------------------------------------------------
  # Shell utilities
  # -------------------------------------------------------------------

  def escape_shell_arg(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  def login_shell_flag(shell, true) do
    shell
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
    |> case do
      name when name in ["bash", "zsh", "sh"] -> " -l"
      _ -> ""
    end
  end

  def login_shell_flag(_shell, false), do: ""

  def random_token do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  def extract_session_id(output) when is_binary(output) do
    case Regex.run(~r/Process running with session ID (\d+)/, output) do
      [_, id] -> id
      _ -> nil
    end
  end

  def extract_exec_output(output) when is_binary(output) do
    case String.split(output, "\nOutput:\n", parts: 2) do
      [_, rest] -> rest
      _ -> output
    end
  end

  def extract_exec_exit_code(output) when is_binary(output) do
    case Regex.run(~r/Process exited with code (\-?\d+)/, output) do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Image attachment
  # -------------------------------------------------------------------

  def attach_image(state, args) do
    path = args["path"] || args["file_path"] || ""

    case Tools.ViewImage.build_message_item(path, cwd: state.cwd) do
      {:ok, message_item} ->
        {"attached local image path", TWHistory.append_history_items(state, [message_item])}

      {:error, reason} when is_binary(reason) ->
        {{:error, reason}, state}

      {:error, reason} ->
        {{:error, "unable to attach image: #{inspect(reason)}"}, state}
    end
  end

  # -------------------------------------------------------------------
  # Sub-agent management
  # -------------------------------------------------------------------

  @subagent_defaults %{
    "explorer" => {"gpt-5.2", "medium"},
    "worker" => {"gpt-5.2-codex", "high"},
    "research" => {"gpt-5.2", "high"},
    "simple" => {"haiku", "medium"},
    "default" => {"gpt-5.2", "high"}
  }

  defp resolve_subagent_model(args, state) do
    agent_type = args["agent_type"]

    {base_model, base_reasoning} =
      case Map.get(@subagent_defaults, agent_type) do
        {m, r} -> {m, r}
        nil -> {state.model, state.reasoning}
      end

    model = if is_binary(args["model"]) and args["model"] != "", do: args["model"], else: base_model
    reasoning = ModelInfo.normalize_reasoning(args["reasoning"], base_reasoning)

    {model, reasoning}
  end

  def spawn_subagent(state, args) do
    active_count = map_size(state.children)
    pending_count = :queue.len(state.pending_agent_spawns)
    total = active_count + pending_count

    cond do
      total >= @hard_subagent_limit ->
        {{:error, %{error: "max_subagents_reached", max_subagents: @hard_subagent_limit}}, state}

      active_count >= @soft_subagent_limit ->
        # Above soft limit: create thread but queue the message send
        agent_id = generate_id()
        task = args["message"] || args["task"] || ""
        {model, reasoning} = resolve_subagent_model(args, state)

        opts = [
          thread_id: agent_id,
          parent_thread_id: state.thread_id,
          cwd: state.cwd,
          model: model,
          reasoning: reasoning,
          tools: TWConfig.filter_tools(args["tools"], model),
          coordination_mode: parse_coordination(args["coordination"])
        ]

        case EchsCore.ThreadWorker.create(opts) do
          {:ok, ^agent_id} ->
            child_pid = lookup_thread_pid(agent_id)
            monitor_ref = if is_pid(child_pid), do: Process.monitor(child_pid), else: nil

            children =
              Map.put(state.children, agent_id, %{pid: child_pid, monitor_ref: monitor_ref})

            pending =
              :queue.in(%{agent_id: agent_id, task: task}, state.pending_agent_spawns)

            broadcast(state, :subagent_queued, %{
              thread_id: state.thread_id,
              agent_id: agent_id,
              task: task
            })

            EchsCore.Telemetry.subagent_spawn(state.thread_id, agent_id, map_size(children))

            {{:ok, %{agent_id: agent_id, status: "queued"}},
             %{state | children: children, pending_agent_spawns: pending}}

          error ->
            {error, state}
        end

      true ->
        # Under soft limit: spawn immediately
        do_spawn_subagent(state, args)
    end
  end

  @doc """
  Drain pending agent spawns when a child completes. Called from ThreadWorker
  after removing the finished child from state.children.
  """
  def drain_pending_spawns(state) do
    if :queue.is_empty(state.pending_agent_spawns) do
      state
    else
      active_count = map_size(state.children)

      if active_count < @soft_subagent_limit do
        case :queue.out(state.pending_agent_spawns) do
          {{:value, %{agent_id: agent_id, task: task}}, remaining} ->
            # Send the queued message to the already-created thread
            _ =
              Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
                _ = EchsCore.ThreadWorker.send_message(agent_id, task)
                :ok
              end)

            broadcast(state, :subagent_spawned, %{
              thread_id: state.thread_id,
              agent_id: agent_id,
              task: task
            })

            drain_pending_spawns(%{state | pending_agent_spawns: remaining})

          {:empty, _} ->
            state
        end
      else
        state
      end
    end
  end

  defp do_spawn_subagent(state, args) do
    agent_id = generate_id()
    task = args["message"] || args["task"] || ""
    {model, reasoning} = resolve_subagent_model(args, state)

    opts = [
      thread_id: agent_id,
      parent_thread_id: state.thread_id,
      cwd: state.cwd,
      model: model,
      reasoning: reasoning,
      tools: TWConfig.filter_tools(args["tools"]),
      coordination_mode: parse_coordination(args["coordination"])
    ]

    case EchsCore.ThreadWorker.create(opts) do
      {:ok, ^agent_id} ->
        _ =
          Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
            _ = EchsCore.ThreadWorker.send_message(agent_id, task)
            :ok
          end)

        broadcast(state, :subagent_spawned, %{
          thread_id: state.thread_id,
          agent_id: agent_id,
          task: task
        })

        child_pid = lookup_thread_pid(agent_id)
        monitor_ref = if is_pid(child_pid), do: Process.monitor(child_pid), else: nil

        children =
          Map.put(state.children, agent_id, %{pid: child_pid, monitor_ref: monitor_ref})

        EchsCore.Telemetry.subagent_spawn(state.thread_id, agent_id, map_size(children))

        {{:ok, %{agent_id: agent_id}}, %{state | children: children}}

      error ->
        {error, state}
    end
  end

  def send_to_subagent(state, args) do
    agent_id = args["id"] || args["agent_id"]
    message = args["message"]

    if not Map.has_key?(state.children, agent_id) do
      {:error, "agent #{agent_id} is not a child of this thread"}
    else
      if args["interrupt"] do
        safe_interrupt(agent_id)
      end

      _ =
        Task.Supervisor.start_child(EchsCore.TaskSupervisor, fn ->
          _ = safe_send_message(agent_id, message)
          :ok
        end)

      {:ok, %{agent_id: agent_id, status: "sent"}}
    end
  end

  def kill_subagent(state, args) do
    agent_id = args["id"] || args["agent_id"]
    safe_kill(agent_id)
    {child, children} = Map.pop(state.children, agent_id)

    if child && child.monitor_ref do
      Process.demonitor(child.monitor_ref, [:flush])
    end

    # Remove from pending spawns queue if it was queued
    pending =
      state.pending_agent_spawns
      |> :queue.to_list()
      |> Enum.reject(fn entry -> entry.agent_id == agent_id end)
      |> :queue.from_list()

    EchsCore.Telemetry.subagent_terminate(state.thread_id, agent_id, map_size(children))

    {:ok, %{state | children: children, pending_agent_spawns: pending}}
  end

  # -------------------------------------------------------------------
  # Agent waiting
  # -------------------------------------------------------------------

  def wait_for_agents(_state, args) do
    agent_ids = args["ids"] || args["agent_ids"] || []
    mode = args["mode"] || "any"

    timeout =
      args["timeout_ms"]
      |> default_wait_timeout()
      |> clamp_wait_timeout()

    start_time = System.monotonic_time(:millisecond)
    results = %{}

    wait_loop(agent_ids, mode, timeout, start_time, results)
  end

  def wait_loop([], _mode, _timeout, _start_time, results) do
    {:ok, %{results: results, timed_out: false}}
  end

  def wait_loop(agent_ids, mode, timeout, start_time, results) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= timeout do
      {:ok, %{results: results, timed_out: true}}
    else
      states =
        Enum.into(agent_ids, %{}, fn id ->
          {id, safe_get_state(id)}
        end)

      {completed, still_running} =
        Enum.split_with(agent_ids, fn id ->
          case Map.get(states, id) do
            %{status: :idle} -> true
            nil -> true
            _ -> false
          end
        end)

      new_results =
        Enum.reduce(completed, results, fn id, acc ->
          case Map.get(states, id) do
            %{history_items: history} ->
              Map.put(acc, id, %{status: :completed, history: history})

            nil ->
              Map.put(acc, id, %{status: :not_found})

            _ ->
              Map.put(acc, id, %{status: :unknown})
          end
        end)

      case mode do
        "all" when still_running == [] ->
          {:ok, %{results: new_results, timed_out: false}}

        "any" when completed != [] ->
          {:ok, %{results: new_results, timed_out: false, remaining: still_running}}

        _ ->
          # TODO: Replace polling with Process.monitor notifications for better
          # efficiency. Current approach polls at 500ms which is acceptable for
          # the typical sub-agent count (<20).
          Process.sleep(500)
          wait_loop(still_running, mode, timeout, start_time, new_results)
      end
    end
  end

  def default_wait_timeout(nil), do: 600_000
  def default_wait_timeout(timeout), do: timeout

  def clamp_wait_timeout(timeout) do
    timeout
    |> max(10_000)
    |> min(300_000)
  end

  # -------------------------------------------------------------------
  # Blackboard operations
  # -------------------------------------------------------------------

  def blackboard_write(state, args) do
    opts = [
      notify_parent: args["notify_parent"] || false,
      steer_message: args["steer_message"],
      by: state.thread_id,
      parent_thread_id: state.parent_thread_id
    ]

    # Use global blackboard for cross-agent coordination
    Blackboard.set(EchsCore.Blackboard.Global, args["key"], args["value"], opts)
    "OK: wrote '#{args["key"]}'"
  end

  def blackboard_read(_state, args) do
    # Use global blackboard for cross-agent coordination
    case Blackboard.get(EchsCore.Blackboard.Global, args["key"]) do
      {:ok, value} -> "Value: #{inspect(value)}"
      :not_found -> "Key '#{args["key"]}' not found"
    end
  end

  # -------------------------------------------------------------------
  # exec_command / write_stdin
  # -------------------------------------------------------------------

  def exec_command(state, args) do
    cmd = args["cmd"] || args["command"]
    cwd = args["workdir"] || state.cwd
    shell = args["shell"] || System.get_env("SHELL") || "/bin/bash"
    login = Map.get(args, "login", true)
    tty = Map.get(args, "tty", false)
    yield_time_ms = Map.get(args, "yield_time_ms", 10_000)
    max_tokens = Map.get(args, "max_output_tokens", 10_000)

    if is_binary(cmd) and cmd != "" do
      argv = Tools.Exec.command_args(shell, cmd, login)

      case maybe_intercept_apply_patch(state, "exec_command", argv, cwd) do
        :not_apply_patch ->
          Tools.Exec.exec_command(
            cmd: cmd,
            cwd: cwd,
            shell: shell,
            login: login,
            tty: tty,
            yield_time_ms: yield_time_ms,
            max_output_tokens: max_tokens
          )

        {:error, reason} ->
          {:error, reason}

        other ->
          other
      end
    else
      {:error, "exec_command requires cmd (or command)"}
    end
  end

  def maybe_intercept_apply_patch(_state, tool_name, command, cwd) do
    case Tools.ApplyPatchInvocation.maybe_parse_verified(command, cwd) do
      {:ok, %{patch: patch, cwd: patch_cwd}} ->
        Logger.warning(
          "apply_patch was requested via #{tool_name}. Use the apply_patch tool instead of exec_command."
        )

        Tools.ApplyPatch.apply(patch, cwd: patch_cwd)

      {:error, reason} ->
        {:error, "apply_patch verification failed: #{reason}"}

      :not_apply_patch ->
        :not_apply_patch
    end
  end

  def write_stdin(_state, args) do
    session_id = args["session_id"]
    chars = args["chars"] || ""
    yield_time_ms = Map.get(args, "yield_time_ms", 250)
    max_tokens = Map.get(args, "max_output_tokens", 10_000)

    Tools.Exec.write_stdin(
      session_id: session_id,
      chars: chars,
      yield_time_ms: yield_time_ms,
      max_output_tokens: max_tokens
    )
  end

  # -------------------------------------------------------------------
  # Custom tool execution
  # -------------------------------------------------------------------

  def execute_custom_tool(state, name, args) do
    case Map.fetch(state.tool_handlers, name) do
      {:ok, handler} ->
        ctx = %{thread_id: state.thread_id, cwd: state.cwd, blackboard: state.blackboard}

        result =
          try do
            invoke_tool_handler(handler, args, ctx)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, reason}
          end

        {result, state}

      :error ->
        {{:error, "Unknown tool: #{name}"}, state}
    end
  end

  def invoke_tool_handler(handler, args, ctx) when is_function(handler, 2) do
    handler.(args, ctx)
  end

  def invoke_tool_handler(handler, args, _ctx) when is_function(handler, 1) do
    handler.(args)
  end

  def invoke_tool_handler({mod, fun}, args, ctx) do
    call_mfa(mod, fun, args, ctx, [])
  end

  def invoke_tool_handler({mod, fun, extra}, args, ctx) when is_list(extra) do
    call_mfa(mod, fun, args, ctx, extra)
  end

  def invoke_tool_handler(_handler, _args, _ctx) do
    {:error, :invalid_handler}
  end

  def call_mfa(mod, fun, args, ctx, extra) do
    cond do
      function_exported?(mod, fun, 2 + length(extra)) ->
        apply(mod, fun, [args, ctx | extra])

      function_exported?(mod, fun, 1 + length(extra)) ->
        apply(mod, fun, [args | extra])

      function_exported?(mod, fun, length(extra)) ->
        apply(mod, fun, extra)

      true ->
        {:error, :handler_not_exported}
    end
  end

  # -------------------------------------------------------------------
  # Coordination helpers
  # -------------------------------------------------------------------

  def parse_coordination(nil), do: :hierarchical
  def parse_coordination("hierarchical"), do: :hierarchical
  def parse_coordination("blackboard"), do: :blackboard
  def parse_coordination("peer"), do: :peer
  def parse_coordination(_), do: :hierarchical

  def lookup_thread_pid(thread_id) do
    case Registry.lookup(EchsCore.Registry, thread_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  def safe_get_state(thread_id) do
    try do
      EchsCore.ThreadWorker.get_state(thread_id)
    catch
      :exit, _ -> nil
    end
  end

  def safe_send_message(thread_id, message) do
    try do
      EchsCore.ThreadWorker.send_message(thread_id, message)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  def safe_interrupt(thread_id) do
    try do
      EchsCore.ThreadWorker.interrupt(thread_id)
    catch
      :exit, _ -> :ok
    end
  end

  def safe_kill(thread_id) do
    try do
      EchsCore.ThreadWorker.kill(thread_id)
    catch
      :exit, _ -> :ok
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp generate_id do
    "thr_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp broadcast(state, event_type, data) do
    data =
      data
      |> maybe_put(:message_id, Map.get(state, :current_message_id))
      |> maybe_put(:trace_id, Map.get(state, :trace_id))

    Phoenix.PubSub.broadcast(
      EchsCore.PubSub,
      "thread:#{state.thread_id}",
      {event_type, data}
    )
  end

  defp maybe_put(data, _key, nil), do: data
  defp maybe_put(data, key, value), do: Map.put_new(data, key, value)
end
