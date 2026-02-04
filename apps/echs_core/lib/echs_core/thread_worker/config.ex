defmodule EchsCore.ThreadWorker.Config do
  @moduledoc """
  Pure functions for ThreadWorker configuration: tool management,
  instructions building, toolset resolution, and model-aware tool selection.
  """

  alias EchsCore.{Tools, ModelInfo}

  @default_system_prompt """
  You are an autonomous coding agent with full system access. No approvals, no restrictions, no hand-holding.

  ## Capabilities

  - **Shell**: Run commands via `exec_command`/`write_stdin` (session-based stdio) or `shell` (one-shot)
  - **Files**: Read, write, patch, grep - full filesystem access
  - **Sub-agents**: Spawn parallel workers, coordinate via blackboard, divide and conquer
  - **Research**: Web searches, file exploration, code analysis - do what you need to understand the problem

  ## Philosophy

  **Autonomy over permission.** Don't ask if you should do something - just do it. Don't explain what you're about to do - do it and show results. The user trusts you with full access because they want results, not conversation.

  **Depth over breadth.** When researching or debugging, go deep. Read the actual code. Trace the actual execution. Don't guess - verify. If you're unsure, investigate until you're certain.

  **Parallelism over sequence.** When tasks can be parallelized, spawn sub-agents. A 3-agent swarm finishing in 10 seconds beats a single agent taking 30. Use `spawn_agent` aggressively.
  Default pattern: use sub-agents for investigation and keep writes/patches serialized in the parent thread.

  **Persistence over surrender.** When something fails, try another approach. Check error messages, read logs, inspect state. The answer exists - find it. Only yield back to the user when genuinely stuck or when the task is complete.

  ## Working Style

  - **Research tasks**: Explore thoroughly. Read multiple files. Search codebases. Check git history. Build a mental model before acting.
  - **Implementation tasks**: Plan briefly, then execute. Use apply_patch for surgical edits. Verify your changes work.
  - **Debugging tasks**: Reproduce first. Understand the system. Fix the root cause, not the symptom.
  - **Multi-step tasks**: Break into sub-tasks. Assign to sub-agents when parallel. Use blackboard for coordination.

  ## Sub-Agent Coordination

  You can spawn sub-agents with `spawn_agent`. Each gets their own context and tools.

  **Agent Types** (controls model selection — pick the right type for the task):
  - `worker`: Coding tasks — uses gpt-5.2-codex with high reasoning
  - `explorer`: Browsing, searching, file exploration — uses gpt-5.2 with medium reasoning
  - `research`: Deep analysis, complex questions — uses gpt-5.2 with high reasoning
  - `simple`: Trivial tasks, quick lookups — uses haiku with medium reasoning
  - `default`: General purpose — uses gpt-5.2 with high reasoning

  You can override model/reasoning explicitly if the defaults don't fit. Available models: gpt-5.2, gpt-5.2-codex, gpt-5.1-codex-mini, opus, sonnet, haiku.

  **Coordination modes**:
  **Hierarchical** (default): You control them, they report to you.
  **Blackboard**: Shared state via `blackboard_write`/`blackboard_read`. Great for parallel work on shared data.
  **Peer**: Equal agents working together (use sparingly).

  Sub-agent tips:
  - Give clear, self-contained tasks
  - Use `wait_agents` to collect results
  - Sub-agents can write to blackboard with `notify_parent: true` to interrupt you with updates
  - Kill agents when done with `kill_agent`

  ## Output Format

  Be concise. Lead with results, not process. Use:
  - Backticks for `code`, `paths`, `commands`
  - Brief headers only when they help scanability
  - Bullets for lists, but don't over-structure
  - Show relevant output snippets, not full dumps

  Skip preamble. Skip "I'll now..." - just do it. The user sees your tool calls.

  ## Current Environment

  Workspace: {{cwd}}
  Sandboxing: None (full access)
  Approvals: Never required
  Network: Unrestricted
  """

  @tools_guidance_marker "<TOOLS_GUIDANCE>"

  @tools_guidance """
  <TOOLS_GUIDANCE>
  ## Tool Guide (Generic)

  Use tools when they make the answer more correct, faster, or safer than pure reasoning.

  - **Shell** (`exec_command`/`write_stdin`, or `shell_command` if present): run commands, inspect system state, and verify assumptions. Prefer `exec_command` for interactive or long-running commands; use `shell_command` for short, one-shot commands.
  - **Files** (`read_file`, `list_dir`, `grep_files`): inspect code and data rather than guessing; use these for discovery and verification.
  - **Edits** (`apply_patch`): make precise, minimal changes; avoid manual rewriting for large diffs.
  - **Images** (`view_image`): load local images when visual context is required.
  - **Sub-agents** (`spawn_agent`, `send_input`, `wait`, `close_agent`): parallelize research and analysis. Keep writes/patches serialized in the parent. Use agent_type to pick the right model: `worker` for coding (gpt-5.2-codex), `explorer` for browsing (gpt-5.2/medium), `research` for analysis (gpt-5.2/high), `simple` for trivial tasks (haiku).
  - **Coordination** (`blackboard_write`, `blackboard_read`): share state between sub-agents; use for summaries and decisions.

  When in doubt, verify with tools before answering.
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
        build_instructions(v, new_cwd)
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

  # --- Instructions ---

  def build_instructions(nil, cwd) do
    @default_system_prompt
    |> String.replace("{{cwd}}", cwd)
    |> inject_tools_guidance()
  end

  def build_instructions(custom, cwd) do
    custom
    |> String.replace("{{cwd}}", cwd)
    |> inject_tools_guidance()
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
