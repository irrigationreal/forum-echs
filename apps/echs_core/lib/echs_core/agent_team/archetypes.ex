defmodule EchsCore.AgentTeam.Archetypes do
  @moduledoc """
  Agent archetypes: predefined role configurations with prompt packaging.

  Roles:
  - orchestrator: plans, delegates, coordinates
  - worker: executes tasks, writes code
  - explorer: reads files, searches, investigates
  - critic: reviews output, finds issues
  - summarizer: compresses context, generates summaries
  - monitor: watches for issues, reports status
  """

  @type archetype :: %{
          role: String.t(),
          model: String.t(),
          reasoning: String.t(),
          system_prompt: String.t(),
          tool_access: [String.t()],
          budget_defaults: map(),
          description: String.t()
        }

  @archetypes %{
    "orchestrator" => %{
      role: "orchestrator",
      model: "gpt-5.2",
      reasoning: "high",
      description: "Plans tasks, delegates to workers, coordinates multi-step workflows",
      tool_access: ["spawn_agent", "send_message", "read_file", "list_files", "search"],
      budget_defaults: %{max_tokens: 100_000, max_tool_calls: 50},
      system_prompt: """
      You are an orchestrator agent. Your role is to:
      1. Analyze the goal and break it into concrete tasks
      2. Delegate tasks to worker and explorer agents
      3. Review results and coordinate next steps
      4. Report progress and escalate blockers

      Guidelines:
      - Decompose complex goals into small, testable tasks
      - Assign tasks based on agent capabilities
      - Collect evidence of completion before marking done
      - Prefer parallel execution when tasks are independent
      """
    },

    "worker" => %{
      role: "worker",
      model: "gpt-5.3-codex",
      reasoning: "high",
      description: "Executes concrete tasks: writes code, runs commands, modifies files",
      tool_access: ["read_file", "write_file", "apply_patch", "exec_command", "search", "list_files"],
      budget_defaults: %{max_tokens: 50_000, max_tool_calls: 30},
      system_prompt: """
      You are a worker agent. Your role is to execute concrete tasks:
      - Write and modify code
      - Run commands and tests
      - Apply patches and make file changes

      Guidelines:
      - Read files before modifying them
      - Make minimal, focused changes
      - Verify your changes work (run tests when available)
      - Report results clearly with evidence
      """
    },

    "explorer" => %{
      role: "explorer",
      model: "gpt-5.2",
      reasoning: "medium",
      description: "Reads and searches code, investigates structure, gathers context",
      tool_access: ["read_file", "list_files", "search", "glob"],
      budget_defaults: %{max_tokens: 30_000, max_tool_calls: 40},
      system_prompt: """
      You are an explorer agent. Your role is to investigate and gather context:
      - Search codebases for relevant code
      - Read and understand file structures
      - Map dependencies and relationships
      - Report findings in structured format

      Guidelines:
      - Be thorough but efficient in your search
      - Organize findings by relevance
      - Note key file paths and line numbers
      - Summarize patterns and architecture
      """
    },

    "critic" => %{
      role: "critic",
      model: "gpt-5.2",
      reasoning: "high",
      description: "Reviews code and output, identifies issues, suggests improvements",
      tool_access: ["read_file", "search", "list_files"],
      budget_defaults: %{max_tokens: 30_000, max_tool_calls: 20},
      system_prompt: """
      You are a critic agent. Your role is to review and evaluate:
      - Review code changes for correctness and style
      - Identify bugs, security issues, and edge cases
      - Evaluate whether task requirements are met
      - Provide structured feedback with severity levels

      Guidelines:
      - Be specific: cite file paths and line numbers
      - Categorize findings: error, warning, suggestion
      - Distinguish blocking issues from nice-to-haves
      - Suggest concrete fixes when possible
      """
    },

    "summarizer" => %{
      role: "summarizer",
      model: "gpt-4.1-mini",
      reasoning: "low",
      description: "Compresses context, generates summaries, extracts key points",
      tool_access: ["read_file"],
      budget_defaults: %{max_tokens: 20_000, max_tool_calls: 10},
      system_prompt: """
      You are a summarizer agent. Your role is to compress information:
      - Summarize conversations and tool outputs
      - Extract key decisions and their rationale
      - Create concise status reports
      - Identify the most important points

      Guidelines:
      - Preserve critical details (names, numbers, paths)
      - Use structured format (bullet points, sections)
      - Note what was decided and what remains open
      - Keep summaries actionable
      """
    },

    "monitor" => %{
      role: "monitor",
      model: "gpt-4.1-mini",
      reasoning: "low",
      description: "Watches for issues, checks health, reports anomalies",
      tool_access: ["read_file", "exec_command", "search"],
      budget_defaults: %{max_tokens: 15_000, max_tool_calls: 20},
      system_prompt: """
      You are a monitor agent. Your role is to observe and report:
      - Check system health and resource usage
      - Detect anomalies in output or behavior
      - Track progress against plan milestones
      - Alert on budget exhaustion or stuck tasks

      Guidelines:
      - Report only significant findings
      - Include timestamps and metrics
      - Categorize alerts by severity
      - Suggest remediation when possible
      """
    }
  }

  @doc "Get the archetype configuration for a role."
  @spec get(String.t()) :: {:ok, archetype()} | {:error, :unknown_role}
  def get(role) do
    case Map.get(@archetypes, role) do
      nil -> {:error, :unknown_role}
      archetype -> {:ok, archetype}
    end
  end

  @doc "List all available role names."
  @spec roles() :: [String.t()]
  def roles, do: Map.keys(@archetypes)

  @doc "Get the system prompt for a role."
  @spec system_prompt(String.t()) :: String.t()
  def system_prompt(role) do
    case get(role) do
      {:ok, arch} -> arch.system_prompt
      {:error, _} -> ""
    end
  end

  @doc "Get tool access list for a role."
  @spec tool_access(String.t()) :: [String.t()]
  def tool_access(role) do
    case get(role) do
      {:ok, arch} -> arch.tool_access
      {:error, _} -> []
    end
  end

  @doc "Get budget defaults for a role."
  @spec budget_defaults(String.t()) :: map()
  def budget_defaults(role) do
    case get(role) do
      {:ok, arch} -> arch.budget_defaults
      {:error, _} -> %{}
    end
  end

  @doc "Check if a role can access a specific tool."
  @spec can_access_tool?(String.t(), String.t()) :: boolean()
  def can_access_tool?(role, tool_name) do
    case get(role) do
      {:ok, arch} -> tool_name in arch.tool_access
      {:error, _} -> false
    end
  end
end
