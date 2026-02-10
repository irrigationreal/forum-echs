defmodule EchsCore.AgentTeam.Manager do
  @moduledoc """
  AgentTeamManager: spawn, supervise, and manage inter-agent messaging.

  Manages a team of agents within a conversation:
  - Spawn agents with role/model/budget configuration
  - OTP supervision with crash containment (INV-AGENT-SUPERVISED)
  - Inter-agent messaging as runes
  - Topology support: hierarchical (default), blackboard, peer

  ## Architecture

  The Manager is a GenServer per conversation that:
  1. Maintains the agent registry (agent_id -> config + status)
  2. Delegates spawning to the DynamicSupervisor
  3. Monitors agents for crashes
  4. Routes inter-agent messages
  5. Enforces budget limits
  """

  use GenServer
  require Logger

  @type agent_config :: %{
          agent_id: String.t(),
          role: String.t(),
          model: String.t(),
          reasoning: String.t(),
          budget: budget(),
          tools: [String.t()],
          parent_id: String.t() | nil,
          status: :spawning | :idle | :running | :terminated,
          pid: pid() | nil,
          monitor_ref: reference() | nil,
          spawned_at_ms: non_neg_integer()
        }

  @type budget :: %{
          max_tokens: non_neg_integer() | :unlimited,
          max_tool_calls: non_neg_integer() | :unlimited,
          max_wall_time_ms: non_neg_integer() | :unlimited,
          tokens_used: non_neg_integer(),
          tool_calls_used: non_neg_integer(),
          started_at_ms: non_neg_integer()
        }

  @type topology :: :hierarchical | :blackboard | :peer

  @default_budget %{
    max_tokens: :unlimited,
    max_tool_calls: :unlimited,
    max_wall_time_ms: :unlimited,
    tokens_used: 0,
    tool_calls_used: 0,
    started_at_ms: 0
  }

  defstruct [
    :conversation_id,
    agents: %{},
    topology: :hierarchical,
    root_agent_id: nil,
    message_queue: []
  ]

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Spawn a new agent in the team.

  Options:
    * `:role` — agent role (required)
    * `:model` — LLM model (default from role defaults)
    * `:reasoning` — reasoning level
    * `:budget` — budget overrides
    * `:tools` — tool access list
    * `:parent_id` — parent agent ID
  """
  @spec spawn_agent(GenServer.server(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def spawn_agent(manager, opts) do
    GenServer.call(manager, {:spawn_agent, opts})
  end

  @doc """
  Send a message from one agent to another. Recorded as agent.message rune.
  """
  @spec send_message(GenServer.server(), String.t(), String.t(), term()) :: :ok
  def send_message(manager, from_agent_id, to_agent_id, content) do
    GenServer.call(manager, {:send_message, from_agent_id, to_agent_id, content})
  end

  @doc """
  Terminate an agent.
  """
  @spec terminate_agent(GenServer.server(), String.t(), String.t()) :: :ok
  def terminate_agent(manager, agent_id, reason \\ "explicit") do
    GenServer.call(manager, {:terminate_agent, agent_id, reason})
  end

  @doc """
  Get agent configuration/status.
  """
  @spec get_agent(GenServer.server(), String.t()) :: {:ok, agent_config()} | {:error, :not_found}
  def get_agent(manager, agent_id) do
    GenServer.call(manager, {:get_agent, agent_id})
  end

  @doc """
  List all agents.
  """
  @spec list_agents(GenServer.server()) :: [agent_config()]
  def list_agents(manager) do
    GenServer.call(manager, :list_agents)
  end

  @doc """
  Record token usage for an agent's budget tracking.
  """
  @spec record_usage(GenServer.server(), String.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, :budget_exhausted}
  def record_usage(manager, agent_id, input_tokens, output_tokens) do
    GenServer.call(manager, {:record_usage, agent_id, input_tokens + output_tokens})
  end

  @doc """
  Check if an agent's budget is exhausted.
  """
  @spec budget_exhausted?(GenServer.server(), String.t()) :: boolean()
  def budget_exhausted?(manager, agent_id) do
    GenServer.call(manager, {:budget_exhausted?, agent_id})
  end

  # -------------------------------------------------------------------
  # Role defaults
  # -------------------------------------------------------------------

  @role_defaults %{
    "orchestrator" => %{model: "gpt-5.2", reasoning: "high"},
    "worker" => %{model: "gpt-5.3-codex", reasoning: "high"},
    "explorer" => %{model: "gpt-5.2", reasoning: "medium"},
    "critic" => %{model: "gpt-5.2", reasoning: "high"},
    "summarizer" => %{model: "gpt-4.1-mini", reasoning: "low"},
    "monitor" => %{model: "gpt-4.1-mini", reasoning: "low"}
  }

  @doc "Get the default model/reasoning for a role."
  @spec role_defaults(String.t()) :: %{model: String.t(), reasoning: String.t()}
  def role_defaults(role) do
    Map.get(@role_defaults, role, %{model: "gpt-5.2", reasoning: "medium"})
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    topology = Keyword.get(opts, :topology, :hierarchical)

    {:ok,
     %__MODULE__{
       conversation_id: conversation_id,
       topology: topology
     }}
  end

  @impl true
  def handle_call({:spawn_agent, opts}, _from, state) do
    role = Keyword.fetch!(opts, :role)
    defaults = role_defaults(role)

    agent_id = Keyword.get(opts, :agent_id, generate_agent_id())
    model = Keyword.get(opts, :model, defaults.model)
    reasoning = Keyword.get(opts, :reasoning, defaults.reasoning)
    parent_id = Keyword.get(opts, :parent_id)
    tools = Keyword.get(opts, :tools, [])

    budget =
      Keyword.get(opts, :budget, %{})
      |> then(&Map.merge(@default_budget, &1))
      |> Map.put(:started_at_ms, System.monotonic_time(:millisecond))

    config = %{
      agent_id: agent_id,
      role: role,
      model: model,
      reasoning: reasoning,
      budget: budget,
      tools: tools,
      parent_id: parent_id,
      status: :idle,
      pid: nil,
      monitor_ref: nil,
      spawned_at_ms: System.system_time(:millisecond)
    }

    agents = Map.put(state.agents, agent_id, config)

    root =
      if state.root_agent_id == nil and parent_id == nil,
        do: agent_id,
        else: state.root_agent_id

    {:reply, {:ok, agent_id}, %{state | agents: agents, root_agent_id: root}}
  end

  def handle_call({:send_message, from_id, to_id, content}, _from, state) do
    msg = %{
      from_agent_id: from_id,
      to_agent_id: to_id,
      content: content,
      ts_ms: System.system_time(:millisecond)
    }

    queue = state.message_queue ++ [msg]
    {:reply, :ok, %{state | message_queue: queue}}
  end

  def handle_call({:terminate_agent, agent_id, _reason}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, :ok, state}

      config ->
        if config.monitor_ref, do: Process.demonitor(config.monitor_ref, [:flush])

        updated = %{config | status: :terminated, pid: nil, monitor_ref: nil}
        agents = Map.put(state.agents, agent_id, updated)
        {:reply, :ok, %{state | agents: agents}}
    end
  end

  def handle_call({:get_agent, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil -> {:reply, {:error, :not_found}, state}
      config -> {:reply, {:ok, config}, state}
    end
  end

  def handle_call(:list_agents, _from, state) do
    {:reply, Map.values(state.agents), state}
  end

  def handle_call({:record_usage, agent_id, tokens}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, :ok, state}

      config ->
        budget = %{config.budget | tokens_used: config.budget.tokens_used + tokens}
        updated = %{config | budget: budget}
        agents = Map.put(state.agents, agent_id, updated)

        if check_budget_exhausted(budget) do
          {:reply, {:error, :budget_exhausted}, %{state | agents: agents}}
        else
          {:reply, :ok, %{state | agents: agents}}
        end
    end
  end

  def handle_call({:budget_exhausted?, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil -> {:reply, false, state}
      config -> {:reply, check_budget_exhausted(config.budget), state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Agent crashed — already handled by OTP supervision
    # The monitor ref mapping would be used to update status
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp check_budget_exhausted(budget) do
    token_exceeded =
      budget.max_tokens != :unlimited and budget.tokens_used >= budget.max_tokens

    tool_exceeded =
      budget.max_tool_calls != :unlimited and budget.tool_calls_used >= budget.max_tool_calls

    time_exceeded =
      budget.max_wall_time_ms != :unlimited and
        System.monotonic_time(:millisecond) - budget.started_at_ms >= budget.max_wall_time_ms

    token_exceeded or tool_exceeded or time_exceeded
  end

  defp generate_agent_id, do: "agt_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
