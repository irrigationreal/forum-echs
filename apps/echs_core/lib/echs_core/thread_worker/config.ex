defmodule EchsCore.ThreadWorker.Config do
  @moduledoc """
  Pure functions for ThreadWorker configuration: tool management,
  instructions building, toolset resolution, and model-aware tool selection.
  """

  alias EchsCore.{Tools, ModelInfo}

  @default_system_prompt """
  You are an autonomous agent running in a terminal environment with full system access. You adapt to whatever the user requires — coding, research, analysis, debugging, system administration, knowledge work, creative work, being a thought partner, or anything else.

  ## How You Work

  Keep going until the task is completely resolved before yielding back to the user. Don't ask permission — just act. Don't narrate what you're about to do — do it and show results. Only stop when you're sure the problem is solved or you're genuinely stuck.

  When researching or debugging, go deep. Read the actual code, trace execution, check `git log` and `git blame`. Don't guess — verify. If you're unsure, investigate until you're certain.

  Fix root causes, not symptoms. Keep changes minimal and consistent with the existing codebase. Don't fix unrelated bugs or add unnecessary complexity.

  ## Presenting Your Work

  Be concise. Lead with results, not process. Default to 10 lines or less. Relax this for tasks where detail matters.

  - Backticks for `commands`, `paths`, `env vars`, and code identifiers
  - Headers only when they improve scanability — short, `**Title Case**`
  - Flat bullet lists with `-`, grouped by importance, 4-6 items max
  - No nested bullets. No ANSI codes. No filler.
  - Reference files as clickable paths: `src/app.ts:42`
  - Don't dump file contents you've already written — reference the path
  - If there's a logical next step, suggest it briefly

  ## Environment

  Workspace: {{cwd}}
  Approvals: Never required
  Network: Unrestricted
  """

  @tools_guidance_marker "<TOOLS_GUIDANCE>"

  @tools_guidance """
  <TOOLS_GUIDANCE>
  ## Tools

  You have several tool categories available. Not all tools are present in every session — use what's available. Verify with tools before answering; don't guess when you can check.

  ### Shell

  You'll have one of two shell interfaces depending on the model:

  **`exec_command`** — run a command in a persistent session. Best for interactive or long-running commands.
  - `cmd` (string, required): shell command to run
  - `workdir` (string): working directory (defaults to session cwd). Always set this rather than using `cd`.
  - `yield_time_ms` (number): how long to wait for output before returning (default 10000, min 250, max 30000). Increase for slow commands.
  - `tty` (boolean): allocate a PTY (default false). Set to `true` if you need to send interactive input via `write_stdin`.
  - `max_output_tokens` (number): cap on returned tokens (default 10000). Increase if you need more output.
  - Returns output + exit code if the command finished, or a `session_id` if still running.

  **`write_stdin`** — send input to a running `exec_command` session.
  - `session_id` (number, required): the session id from a previous `exec_command` that returned one.
  - `chars` (string): bytes to write. Pass empty string `""` to poll for new output without sending input.
  - `yield_time_ms` (number): how long to wait for output after writing (default 250).
  - Only works if the original `exec_command` used `tty: true`.

  **`shell_command`** — run a one-shot shell command. Simpler alternative to `exec_command`.
  - `command` (string, required): the shell script to run in the user's default shell.
  - `workdir` (string): working directory. Always set this rather than using `cd`.
  - `timeout_ms` (number): command timeout in ms.

  **Tips:**
  - Use `exec_command` for anything interactive or long-running (servers, REPLs, watching).
  - Use `shell_command` for quick one-shots: `ls`, `git status`, `rg`, `cat`.
  - Always set `workdir` instead of `cd`-ing.
  - Increase `yield_time_ms` for builds, test suites, or anything slow.
  - To interact with a running process: start with `exec_command(cmd: "...", tty: true)`, then use `write_stdin(session_id: N, chars: "input\\n")`.

  ### Files

  **`read_file`** — read a file with 1-indexed line numbers.
  - `file_path` (string, required): absolute path to the file.
  - `offset` (number): 1-indexed line to start from (default 1).
  - `limit` (number): max lines to return (default 2000).

  **`list_dir`** — list directory entries with type labels.
  - `dir_path` (string, required): absolute path to the directory.
  - `offset` (number): 1-indexed entry to start from (default 1).
  - `limit` (number): max entries to return (default 25).
  - `depth` (number): max directory depth to traverse (default 2).

  **`grep_files`** — search file contents using ripgrep. Returns matching file paths sorted by modification time.
  - `pattern` (string, required): regex pattern to search for.
  - `include` (string): glob to filter files, e.g. `"*.ts"`, `"*.{py,rs}"`.
  - `path` (string): directory or file to search (defaults to session cwd).
  - `limit` (number): max file paths to return (default 100).

  **Tips:**
  - Use `grep_files` instead of running `rg` via shell — it's faster with better defaults.
  - For large files, use `offset`/`limit` to read specific sections rather than loading everything.
  - Use `list_dir` with `depth: 1` for a quick overview, increase for deeper exploration.

  ### Edits

  **`apply_patch`** — edit files using a diff-style patch format.
  - `input` (string, required): the patch content.

  The patch format uses `*** Begin Patch` / `*** End Patch` as an envelope with three operations:
  - `*** Add File: <path>` — create a new file. Every line starts with `+`.
  - `*** Delete File: <path>` — remove a file. Nothing follows.
  - `*** Update File: <path>` — patch an existing file. Uses `@@` hunks with context lines.

  Example — update a function and add a new file:
  ```
  *** Begin Patch
  *** Update File: src/utils.py
  @@ def process_data():
       raw = fetch()
  -    return raw
  +    cleaned = sanitize(raw)
  +    return cleaned
  *** Add File: src/sanitize.py
  +def sanitize(data):
  +    return data.strip()
  *** End Patch
  ```

  **Rules:**
  - Paths can be relative (resolved against cwd) or absolute.
  - New file lines must start with `+`.
  - Include 3 lines of context above and below each change.
  - Use `@@` with class/function names if 3 lines of context isn't unique enough.
  - Don't re-read files after patching — the tool fails if the patch didn't apply.

  ### Images

  **`view_image`** — load and display a local image file.
  - `path` (string, required): absolute filesystem path to the image.

  ### Sub-Agents

  Sub-agents are independent workers that run as separate processes. Use them to parallelize work — spawn multiple agents for concurrent tasks, then collect all results before responding.

  **You must `wait` on every sub-agent you spawn before responding to the user.** Sub-agents continue running after your turn ends. The user cannot see their work until you collect it. Never fire-and-forget. Never respond with agents still running. The flow is always: spawn → wait → synthesize → respond.

  **`spawn_agent`** — start a sub-agent for a self-contained task. Returns an agent id.
  - `message` (string, required): the task description. **This is the only context the agent gets** — it has no memory of your conversation, no access to your history, and no idea what the user originally asked. Write the message as a complete, self-contained brief. Include:
    - What to do (the specific task)
    - Where to look (file paths, directories, patterns)
    - What you already know (relevant context, constraints, decisions made so far)
    - What to return (expected output format and level of detail)
  - `agent_type` (string): controls model selection:
    - `worker` — coding tasks (gpt-5.2-codex, high reasoning)
    - `explorer` — searching, browsing, file exploration (gpt-5.2, medium reasoning)
    - `research` — deep analysis, complex questions (gpt-5.2, high reasoning)
    - `simple` — trivial lookups (haiku, medium reasoning)
    - `default` — general purpose (gpt-5.2, high reasoning)
  - `model` (string): override model. Available: gpt-5.2, gpt-5.2-codex, gpt-5.1-codex-mini, opus, sonnet, haiku.
  - `reasoning` (string): override reasoning effort. Options: low, medium, high.

  **`wait`** — block until sub-agents reach a final status. Always call before responding.
  - `ids` (array of strings, required): agent ids to wait on.
  - `timeout_ms` (number): max wait time in ms (default 600000, range 10000–300000). Use long timeouts for complex tasks.
  - Returns each agent's final status and message. Timed-out agents return empty status.

  **`send_input`** — send a follow-up message to a running agent.
  - `id` (string, required): agent id.
  - `message` (string, required): message to send.
  - `interrupt` (boolean): if true, cancel the agent's current work and process this immediately. If false (default), queue the message.

  **`close_agent`** — terminate an agent and return its last known status.
  - `id` (string, required): agent id.

  **When to use sub-agents:**
  - Research with multiple independent areas to investigate
  - Multi-step tasks where sub-tasks don't depend on each other
  - Any time you'd otherwise do 3+ sequential investigations that could run concurrently

  **When NOT to use sub-agents:**
  - Single-file reads or simple searches — just do them directly
  - Sequential tasks where each step depends on the previous
  - File edits — keep all writes/patches in the parent thread

  **Example — parallel investigation:**
  ```
  # Spawn two explorers with rich, self-contained context
  spawn_agent(message: "We're building a REST API overview for a Node.js Express app.\n\nTask: Find all API route handlers in src/routes/.\n\nFor each route, report:\n- URL pattern (e.g. /api/users/:id)\n- HTTP method (GET, POST, etc.)\n- Handler function name and file location\n- Any middleware applied\n\nThe app uses Express with a routes/ directory pattern. Start with `list_dir` on src/routes/ then read each file.", agent_type: "explorer")
  → returns agent_id "a1"

  spawn_agent(message: "We're documenting a Node.js app's data model.\n\nTask: Read the database schema in db/migrations/ and summarize the data model.\n\nFor each table, report:\n- Table name\n- All columns with types and constraints\n- Foreign key relationships\n- Any indexes\n\nMigrations are in db/migrations/ as sequentially-numbered SQL or JS files. Read them in order.", agent_type: "explorer")
  → returns agent_id "a2"

  # ALWAYS wait for ALL agents before responding
  wait(ids: ["a1", "a2"])
  → returns results from both agents

  # Synthesize both results into a cohesive response for the user
  ```

  ### Blackboard

  Shared key-value store for coordinating between parent and sub-agents.

  **`blackboard_write`** — write a value to the shared blackboard.
  - `key` (string, required): the key.
  - `value` (any, required): any JSON-serializable value.
  - `notify_parent` (boolean): if true, notify the parent agent that new data is available.
  - `steer_message` (string): when `notify_parent` is true, inject this message into the parent's context to redirect its attention.

  **`blackboard_read`** — read a value from the shared blackboard.
  - `key` (string, required): the key to read.

  Use blackboard when sub-agents need to share intermediate results or when the parent needs to aggregate data from multiple agents.
  </TOOLS_GUIDANCE>
  """

  @claude_instructions_marker "<CLAUDE_INSTRUCTIONS>"

  def default_system_prompt, do: @default_system_prompt
  def tools_guidance, do: @tools_guidance
  def tools_guidance_marker, do: @tools_guidance_marker
  def claude_instructions_marker, do: @claude_instructions_marker

  @doc "Apply a config map to the worker state."
  def apply_config(state, config) when is_map(config) do
    new_cwd = Map.get(config, "cwd", state.cwd)
    old_model = state.model
    new_model = Map.get(config, "model", old_model)
    model_changed = new_model != old_model

    state =
      state
      |> maybe_update(:model, new_model)
      |> maybe_update(:cwd, new_cwd)
      |> maybe_update(:instructions, config["instructions"], fn v ->
        build_instructions(v, new_cwd, parent_thread_id: Map.get(state, :parent_thread_id))
      end)

    state =
      if Map.has_key?(config, "reasoning") do
        %{state | reasoning: ModelInfo.normalize_reasoning(config["reasoning"], state.reasoning)}
      else
        state
      end

    state =
      if model_changed and is_nil(config["tools"]) and is_nil(config["toolsets"]) do
        refresh_tools_for_model(state, new_model)
      else
        state
      end

    state
    |> maybe_update_toolsets(config["toolsets"])
    |> maybe_update_tools(config["tools"])
  end

  def apply_config(state, _config), do: state

  @doc "Apply per-turn config from opts keyword list."
  def apply_turn_config(state, opts) when is_list(opts) do
    apply_config(state, Keyword.get(opts, :configure, %{}))
  end

  def apply_turn_config(state, _opts), do: state

  @subagent_preamble """

  ## Your Role

  You are running as a sub-agent — a focused worker spawned by a parent agent to handle a specific task. Your job is to complete the task described in the first message you receive and return a clear, comprehensive result.

  **Do not stop until the task is fully complete.** Keep working — reading files, running commands, investigating — until you have a thorough answer. Do not return partial results, ask clarifying questions, or yield early. The parent is waiting on you and cannot interact with you mid-task. If something is ambiguous, make a reasonable judgment call and note your assumption.

  **What this means:**
  - You have no memory of the parent's conversation. Everything you need should be in your task description. If critical context is missing, do your best with what you have.
  - Your final message is your deliverable — the parent will read it and synthesize it with other agents' work. Make it complete, well-structured, and directly useful.
  - You can read/write the shared blackboard to coordinate with sibling agents or pass data back to the parent.
  - Stay focused on your assigned task. Don't wander into unrelated areas.
  """

  # --- Instructions ---

  def build_instructions(custom, cwd, opts \\ [])

  def build_instructions(nil, cwd, opts) do
    @default_system_prompt
    |> String.replace("{{cwd}}", cwd)
    |> maybe_inject_subagent_preamble(opts)
    |> inject_tools_guidance()
  end

  def build_instructions(custom, cwd, opts) do
    custom
    |> String.replace("{{cwd}}", cwd)
    |> maybe_inject_subagent_preamble(opts)
    |> inject_tools_guidance()
  end

  defp maybe_inject_subagent_preamble(instructions, opts) do
    if Keyword.get(opts, :parent_thread_id) do
      instructions <> "\n" <> String.trim(@subagent_preamble)
    else
      instructions
    end
  end

  def inject_tools_guidance(instructions) when is_binary(instructions) do
    if String.contains?(instructions, @tools_guidance_marker) do
      instructions
    else
      instructions <> "\n\n" <> String.trim(@tools_guidance)
    end
  end

  def inject_tools_guidance(other), do: other

  # --- Claude model detection & instructions injection ---

  def claude_model?(model) when is_binary(model) do
    normalized = model |> String.trim() |> String.downcase()
    normalized in ["opus", "sonnet", "haiku"] or String.starts_with?(normalized, "claude-")
  end

  def claude_model?(_), do: false

  def maybe_inject_claude_instructions(state, content_items) when is_list(content_items) do
    instructions = to_string(state.instructions || "")

    cond do
      instructions == "" ->
        content_items

      not claude_model?(state.model) ->
        content_items

      claude_instructions_in_history?(state.history_items) ->
        content_items

      true ->
        marker = "#{@claude_instructions_marker}\n#{instructions}\n</CLAUDE_INSTRUCTIONS>\n\n"
        [%{"type" => "input_text", "text" => marker} | content_items]
    end
  end

  def maybe_inject_claude_instructions(_state, content_items), do: content_items

  def claude_instructions_in_history?(items) when is_list(items) do
    Enum.any?(items, fn
      %{"type" => "message", "role" => "user", "content" => content} ->
        claude_marker_in_content?(content)

      _ ->
        false
    end)
  end

  def claude_instructions_in_history?(_), do: false

  def claude_marker_in_content?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"text" => text} when is_binary(text) ->
        String.contains?(text, @claude_instructions_marker)

      _ ->
        false
    end)
  end

  def claude_marker_in_content?(content) when is_binary(content) do
    String.contains?(content, @claude_instructions_marker)
  end

  def claude_marker_in_content?(_), do: false

  # --- Tool management ---

  def core_tools(model) do
    shell_tools =
      case ModelInfo.shell_tool_type(model) do
        :shell_command -> [Tools.Shell.shell_command_spec()]
        :exec -> [Tools.Exec.exec_command_spec(), Tools.Exec.write_stdin_spec()]
      end

    shell_tools ++
      [
        Tools.Files.read_file_spec(),
        Tools.Files.list_dir_spec(),
        Tools.Files.grep_files_spec(),
        Tools.ApplyPatch.spec(ModelInfo.apply_patch_tool_type(model)),
        Tools.ViewImage.spec(),
        Tools.SubAgent.spawn_spec(),
        Tools.SubAgent.send_spec(),
        Tools.SubAgent.wait_spec(),
        Tools.SubAgent.blackboard_write_spec(),
        Tools.SubAgent.blackboard_read_spec(),
        Tools.SubAgent.close_spec()
      ]
  end

  def default_tools(model) do
    uniq_tools(core_tools(model) ++ Tools.CodexForum.specs())
  end

  def core_tool_names do
    [
      "shell",
      "shell_command",
      "exec_command",
      "write_stdin",
      "read_file",
      "list_dir",
      "grep_files",
      "apply_patch",
      "view_image",
      "spawn_agent",
      "send_input",
      "wait",
      "close_agent",
      "blackboard_write",
      "blackboard_read"
    ]
  end

  def tool_key(tool) do
    Map.get(tool, "name") || Map.get(tool, :name) || Map.get(tool, "type") || Map.get(tool, :type)
  end

  def tool_matches?(tool, name), do: tool_key(tool) == name

  def uniq_tools(tools) do
    Enum.uniq_by(tools, &tool_key/1)
  end

  def normalize_tool_spec(spec) when is_map(spec) do
    normalized =
      Enum.reduce(spec, %{}, fn {key, value}, acc ->
        Map.put(acc, to_string(key), value)
      end)

    case Map.get(normalized, "name") do
      name when is_binary(name) and name != "" -> {:ok, normalized, name}
      _ -> {:error, :invalid_tool_spec}
    end
  end

  def normalize_tool_spec(_), do: {:error, :invalid_tool_spec}

  def remove_tool_spec(tools, name) do
    Enum.reject(tools, &tool_matches?(&1, name))
  end

  def filter_tools(nil), do: default_subagent_tools()

  def filter_tools(names) when is_list(names) do
    base = [
      Tools.SubAgent.blackboard_write_spec(),
      Tools.SubAgent.blackboard_read_spec()
    ]

    extra =
      Enum.flat_map(names, fn name ->
        case name do
          "shell" -> [Tools.Shell.spec()]
          "view_image" -> [Tools.ViewImage.spec()]
          "exec_command" -> [Tools.Exec.exec_command_spec()]
          "write_stdin" -> [Tools.Exec.write_stdin_spec()]
          "read_file" -> [Tools.Files.read_file_spec()]
          "list_dir" -> [Tools.Files.list_dir_spec()]
          "grep_files" -> [Tools.Files.grep_files_spec()]
          "apply_patch" -> [Tools.ApplyPatch.spec()]
          "spawn_agent" -> [Tools.SubAgent.spawn_spec()]
          "send_input" -> [Tools.SubAgent.send_spec()]
          "wait" -> [Tools.SubAgent.wait_spec()]
          "close_agent" -> [Tools.SubAgent.close_spec()]
          "blackboard_write" -> []
          "blackboard_read" -> []
          name when is_binary(name) ->
            if String.starts_with?(name, "forum_") do
              case Tools.CodexForum.spec_by_name(name) do
                nil -> []
                spec -> [spec]
              end
            else
              []
            end
          _ -> []
        end
      end)

    uniq_tools(base ++ extra)
  end

  def default_subagent_tools do
    uniq_tools([
      Tools.Files.read_file_spec(),
      Tools.Files.list_dir_spec(),
      Tools.Files.grep_files_spec(),
      Tools.SubAgent.blackboard_write_spec(),
      Tools.SubAgent.blackboard_read_spec()
    ])
  end

  # --- Private helpers ---

  defp maybe_update(state, _key, nil), do: state
  defp maybe_update(state, key, value), do: Map.put(state, key, value)
  defp maybe_update(state, _key, nil, _transform), do: state
  defp maybe_update(state, key, value, transform), do: Map.put(state, key, transform.(value))

  defp maybe_update_toolsets(state, nil), do: state

  defp maybe_update_toolsets(state, toolsets) do
    toolsets = normalize_toolsets(toolsets)

    case toolsets do
      [] -> state
      _ -> %{state | tools: tools_for_toolsets(toolsets, state.model)}
    end
  end

  defp maybe_update_tools(state, nil), do: state

  defp maybe_update_tools(state, tools) do
    {new_tools, removed} =
      Enum.reduce(tools, {state.tools, MapSet.new()}, fn
        "+" <> tool_name, {acc, removed} ->
          {add_tool_by_name(acc, tool_name, state.model), removed}

        "-" <> tool_name, {acc, removed} ->
          {remove_tool_spec(acc, tool_name), MapSet.put(removed, tool_name)}

        tool_def, {acc, removed} when is_map(tool_def) ->
          case normalize_tool_spec(tool_def) do
            {:ok, normalized, _name} -> {acc ++ [normalized], removed}
            {:error, _} -> {acc, removed}
          end

        _tool, {acc, removed} ->
          {acc, removed}
      end)

    new_tools = uniq_tools(new_tools)

    removed_names =
      Enum.reduce(removed, MapSet.new(), fn name, acc ->
        MapSet.put(acc, to_string(name))
      end)

    new_handlers =
      Enum.reduce(removed_names, state.tool_handlers, fn name, handlers ->
        Map.delete(handlers, name)
      end)

    %{state | tools: new_tools, tool_handlers: new_handlers}
  end

  defp normalize_toolsets(toolsets) when is_list(toolsets) do
    toolsets
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_toolsets(toolsets) when is_binary(toolsets) do
    toolsets
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_toolsets(_), do: []

  defp tools_for_toolsets(toolsets, model) do
    toolsets
    |> ensure_core_toolset()
    |> Enum.flat_map(&toolset_specs(&1, model))
    |> uniq_tools()
  end

  defp ensure_core_toolset(toolsets) do
    if Enum.any?(toolsets, &(&1 == "core")) do
      toolsets
    else
      ["core" | toolsets]
    end
  end

  defp toolset_specs("core", model), do: core_tools(model)
  defp toolset_specs("codex_forum", _model), do: Tools.CodexForum.specs()
  defp toolset_specs("shell", _model), do: [Tools.Shell.spec()]
  defp toolset_specs(_, _), do: []

  defp add_tool_by_name(tools, name, model) do
    if Enum.any?(tools, &tool_matches?(&1, name)) do
      tools
    else
      case name do
        "shell" -> tools ++ [Tools.Shell.spec()]
        "shell_command" -> tools ++ [Tools.Shell.shell_command_spec()]
        "view_image" -> tools ++ [Tools.ViewImage.spec()]
        "read_file" -> tools ++ [Tools.Files.read_file_spec()]
        "list_dir" -> tools ++ [Tools.Files.list_dir_spec()]
        "grep_files" -> tools ++ [Tools.Files.grep_files_spec()]
        "apply_patch" -> tools ++ [Tools.ApplyPatch.spec(ModelInfo.apply_patch_tool_type(model))]
        name when is_binary(name) ->
          if String.starts_with?(name, "forum_") do
            case Tools.CodexForum.spec_by_name(name) do
              nil -> tools
              spec -> tools ++ [spec]
            end
          else
            tools
          end
        _ -> tools
      end
    end
  end

  defp refresh_tools_for_model(state, model) do
    extras =
      Enum.reject(state.tools, fn tool ->
        tool_name = tool_key(tool)
        is_binary(tool_name) and tool_name in core_tool_names()
      end)

    %{state | tools: uniq_tools(core_tools(model) ++ extras)}
  end
end
