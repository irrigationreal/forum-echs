defmodule EchsCore.ApiV2.Handlers do
  @moduledoc """
  API v2 handler functions.

  Stateless request handlers that can be called from any HTTP framework
  (Plug, Phoenix, etc). Each handler takes parsed params and returns
  a response tuple `{status_code, body}`.

  These handlers bridge v2 API calls to the core modules:
  - Memory.Store for memory CRUD
  - PlanGraph.Plan for plan management
  - AgentTeam.Manager for agent management
  - Checkpoint.Engine for snapshots
  - ToolSystem.ToolRegistry for tool management
  """

  alias EchsCore.Memory.{Memory, Store, Retrieval}
  alias EchsCore.PlanGraph.Plan
  alias EchsCore.AgentTeam.Manager
  alias EchsCore.Checkpoint.{Engine, Rewind}
  alias EchsCore.ToolSystem.{ToolSpec, ToolRegistry}

  # =====================================================================
  # Memory handlers
  # =====================================================================

  @doc "List memories for a conversation."
  @spec list_memories(GenServer.server(), String.t(), map()) :: {integer(), map()}
  def list_memories(store, conversation_id, params) do
    limit = parse_int(params["limit"], 50)
    min_confidence = parse_float(params["min_confidence"], 0.0)
    memory_type = parse_memory_type(params["type"])

    memories =
      if memory_type do
        Store.query_by_type(store, memory_type,
          privacy: :internal, min_confidence: min_confidence, limit: limit)
        |> Enum.filter(&(&1.conversation_id == conversation_id or &1.conversation_id == nil))
      else
        Store.query_by_conversation(store, conversation_id,
          privacy: :internal, min_confidence: min_confidence, limit: limit)
      end

    {200, %{memories: Enum.map(memories, &Memory.to_map/1), count: length(memories)}}
  end

  @doc "Create a memory."
  @spec create_memory(GenServer.server(), String.t(), map()) :: {integer(), map()}
  def create_memory(store, conversation_id, params) do
    mem = Memory.new(
      conversation_id: conversation_id,
      memory_type: parse_memory_type(params["type"]) || :semantic,
      content: params["content"] || "",
      tags: params["tags"] || [],
      confidence: parse_float(params["confidence"], 0.5),
      privacy: parse_privacy(params["privacy"]),
      source_rune_ids: params["source_rune_ids"] || [],
      metadata: params["metadata"] || %{}
    )

    :ok = Store.put(store, mem)
    {201, %{memory: Memory.to_map(mem)}}
  end

  @doc "Get a memory by ID."
  @spec get_memory(GenServer.server(), String.t()) :: {integer(), map()}
  def get_memory(store, memory_id) do
    case Store.get(store, memory_id) do
      {:ok, mem} -> {200, %{memory: Memory.to_map(mem)}}
      {:error, :not_found} -> {404, %{error: "memory not found"}}
    end
  end

  @doc "Update a memory."
  @spec update_memory(GenServer.server(), String.t(), map()) :: {integer(), map()}
  def update_memory(store, memory_id, params) do
    updates =
      []
      |> maybe_add(:content, params["content"])
      |> maybe_add(:tags, params["tags"])
      |> maybe_add(:confidence, params["confidence"])
      |> maybe_add(:privacy, parse_privacy_opt(params["privacy"]))
      |> maybe_add(:metadata, params["metadata"])

    case Store.update(store, memory_id, updates) do
      {:ok, mem} -> {200, %{memory: Memory.to_map(mem)}}
      {:error, :not_found} -> {404, %{error: "memory not found"}}
    end
  end

  @doc "Delete a memory."
  @spec delete_memory(GenServer.server(), String.t()) :: {integer(), map()}
  def delete_memory(store, memory_id) do
    Store.delete(store, memory_id)
    {200, %{ok: true}}
  end

  @doc "Search memories."
  @spec search_memories(GenServer.server(), String.t(), map()) :: {integer(), map()}
  def search_memories(store, conversation_id, params) do
    query = params["query"] || ""
    max_memories = parse_int(params["max_memories"], 10)
    min_confidence = parse_float(params["min_confidence"], 0.3)

    result = Retrieval.retrieve(store, query, %{
      conversation_id: conversation_id,
      max_memories: max_memories,
      min_confidence: min_confidence,
      memory_types: parse_memory_types(params["types"])
    })

    {200, %{
      memories: Enum.map(result.memories, &Memory.to_map/1),
      total_found: result.total_found,
      tokens_used: result.tokens_used,
      truncated: result.truncated
    }}
  end

  # =====================================================================
  # Checkpoint handlers
  # =====================================================================

  @doc "List checkpoints."
  @spec list_checkpoints(String.t()) :: {integer(), map()}
  def list_checkpoints(store_dir) do
    checkpoints = Rewind.list_rewind_points(store_dir)
    {200, %{checkpoints: checkpoints, count: length(checkpoints)}}
  end

  @doc "Create a checkpoint."
  @spec create_checkpoint(map()) :: {integer(), map()}
  def create_checkpoint(params) do
    {:ok, checkpoint} = Engine.create(
      workspace_root: params["workspace_root"],
      store_dir: params["store_dir"],
      trigger: parse_trigger(params["trigger"]),
      linked_call_id: params["linked_call_id"]
    )

    {201, %{checkpoint: checkpoint}}
  rescue
    e ->
      {500, %{error: "checkpoint creation failed", reason: Exception.message(e)}}
  end

  @doc "Restore a checkpoint (rewind)."
  @spec restore_checkpoint(map()) :: {integer(), map()}
  def restore_checkpoint(params) do
    mode = parse_rewind_mode(params["mode"])
    dry_run = params["dry_run"] == true

    case Rewind.rewind(
      store_dir: params["store_dir"],
      checkpoint_id: params["checkpoint_id"],
      workspace_root: params["workspace_root"],
      runelog_dir: params["runelog_dir"],
      mode: mode,
      dry_run: dry_run
    ) do
      {:ok, result} ->
        {200, %{result: result}}

      {:error, reason} ->
        {500, %{error: "rewind failed", reason: inspect(reason)}}
    end
  end

  # =====================================================================
  # Plan handlers
  # =====================================================================

  @doc "Get current plan from an autonomy loop state."
  @spec get_plan(map() | nil) :: {integer(), map()}
  def get_plan(nil), do: {200, %{plan: nil}}

  def get_plan(%Plan{} = plan) do
    {200, %{
      plan: %{
        goal: plan.goal,
        task_count: map_size(plan.tasks),
        task_order: plan.task_order,
        tasks: Enum.map(plan.task_order, fn id ->
          task = plan.tasks[id]
          %{
            id: task.id,
            title: task.title,
            description: task.description,
            status: task.status,
            priority: task.priority,
            deps: task.deps,
            result: task.result
          }
        end),
        status_counts: Plan.status_counts(plan),
        all_terminal: Plan.all_terminal?(plan)
      }
    }}
  end

  @doc "Update a task in a plan."
  @spec update_task(Plan.t(), String.t(), map()) :: {integer(), map()}
  def update_task(plan, task_id, params) do
    updates =
      []
      |> maybe_add(:status, parse_task_status(params["status"]))
      |> maybe_add(:result, params["result"])
      |> maybe_add(:priority, parse_priority(params["priority"]))

    case Plan.update_task(plan, task_id, updates) do
      {:ok, updated_plan} ->
        task = updated_plan.tasks[task_id]
        {200, %{task: %{id: task.id, title: task.title, status: task.status, result: task.result}}}

      {:error, :not_found} ->
        {404, %{error: "task not found"}}
    end
  end

  # =====================================================================
  # Agent handlers
  # =====================================================================

  @doc "List agents."
  @spec list_agents(GenServer.server()) :: {integer(), map()}
  def list_agents(manager) do
    agents = Manager.list_agents(manager)
    {200, %{agents: Enum.map(agents, &sanitize_agent/1), count: length(agents)}}
  end

  @doc "Spawn an agent."
  @spec spawn_agent(GenServer.server(), map()) :: {integer(), map()}
  def spawn_agent(manager, params) do
    role = params["role"] || "worker"
    opts =
      [role: role]
      |> maybe_add_kw(:model, params["model"])
      |> maybe_add_kw(:reasoning, params["reasoning"])
      |> maybe_add_kw(:parent_id, params["parent_id"])

    opts =
      if params["budget"] do
        budget = %{}
          |> maybe_put_int(:max_tokens, params["budget"]["max_tokens"])
          |> maybe_put_int(:max_tool_calls, params["budget"]["max_tool_calls"])
        Keyword.put(opts, :budget, budget)
      else
        opts
      end

    case Manager.spawn_agent(manager, opts) do
      {:ok, agent_id} ->
        {:ok, config} = Manager.get_agent(manager, agent_id)
        {201, %{agent: sanitize_agent(config)}}

      {:error, reason} ->
        {500, %{error: "spawn failed", reason: inspect(reason)}}
    end
  end

  @doc "Get agent status."
  @spec get_agent(GenServer.server(), String.t()) :: {integer(), map()}
  def get_agent(manager, agent_id) do
    case Manager.get_agent(manager, agent_id) do
      {:ok, config} -> {200, %{agent: sanitize_agent(config)}}
      {:error, :not_found} -> {404, %{error: "agent not found"}}
    end
  end

  @doc "Terminate an agent."
  @spec terminate_agent(GenServer.server(), String.t(), String.t()) :: {integer(), map()}
  def terminate_agent(manager, agent_id, reason \\ "api_request") do
    :ok = Manager.terminate_agent(manager, agent_id, reason)
    {200, %{ok: true}}
  end

  # =====================================================================
  # Tool handlers
  # =====================================================================

  @doc "List registered tools."
  @spec list_tools(GenServer.server()) :: {integer(), map()}
  def list_tools(registry) do
    tools = ToolRegistry.list(registry)
    {200, %{tools: Enum.map(tools, &ToolSpec.to_map/1), count: length(tools)}}
  end

  @doc "Register a tool."
  @spec register_tool(GenServer.server(), map()) :: {integer(), map()}
  def register_tool(registry, params) do
    spec = ToolSpec.from_legacy(%{
      "name" => params["name"],
      "description" => params["description"] || "",
      "parameters" => params["parameters"] || %{},
      "side_effects" => params["side_effects"] == true,
      "idempotent" => params["idempotent"] == true,
      "requires_approval" => if(params["requires_approval"] == true, do: "always", else: nil),
      "timeout" => parse_int(params["timeout_ms"], 120_000),
      "provenance" => to_string(parse_provenance(params["provenance"]))
    })

    :ok = ToolRegistry.register(registry, spec.name, spec)
    {201, %{tool: ToolSpec.to_map(spec)}}
  end

  @doc "Unregister a tool."
  @spec unregister_tool(GenServer.server(), String.t()) :: {integer(), map()}
  def unregister_tool(registry, tool_name) do
    ToolRegistry.unregister(registry, tool_name)
    {200, %{ok: true}}
  end

  # =====================================================================
  # Internal helpers
  # =====================================================================

  defp sanitize_agent(config) do
    %{
      agent_id: config.agent_id,
      role: config.role,
      model: config.model,
      reasoning: config.reasoning,
      status: config.status,
      parent_id: config.parent_id,
      budget: %{
        max_tokens: config.budget.max_tokens,
        tokens_used: config.budget.tokens_used,
        max_tool_calls: config.budget.max_tool_calls,
        tool_calls_used: config.budget.tool_calls_used
      }
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(_, default), do: default

  defp parse_float(nil, default), do: default
  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(val, _default) when is_integer(val), do: val / 1
  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_float(_, default), do: default

  defp parse_memory_type(nil), do: nil
  defp parse_memory_type("episodic"), do: :episodic
  defp parse_memory_type("semantic"), do: :semantic
  defp parse_memory_type("procedural"), do: :procedural
  defp parse_memory_type("decision"), do: :decision
  defp parse_memory_type(_), do: nil

  defp parse_memory_types(nil), do: nil
  defp parse_memory_types(types) when is_list(types) do
    types |> Enum.map(&parse_memory_type/1) |> Enum.reject(&is_nil/1)
    |> then(fn l -> if l == [], do: nil, else: l end)
  end
  defp parse_memory_types(_), do: nil

  defp parse_privacy(nil), do: :internal
  defp parse_privacy("public"), do: :public
  defp parse_privacy("internal"), do: :internal
  defp parse_privacy("secret"), do: :secret
  defp parse_privacy(_), do: :internal

  defp parse_privacy_opt(nil), do: nil
  defp parse_privacy_opt(val), do: parse_privacy(val)

  defp parse_trigger(nil), do: :manual
  defp parse_trigger("manual"), do: :manual
  defp parse_trigger("auto_pre_tool"), do: :auto_pre_tool
  defp parse_trigger("policy"), do: :policy
  defp parse_trigger(_), do: :manual

  defp parse_rewind_mode(nil), do: :both
  defp parse_rewind_mode("workspace"), do: :workspace
  defp parse_rewind_mode("conversation"), do: :conversation
  defp parse_rewind_mode("both"), do: :both
  defp parse_rewind_mode(_), do: :both

  defp parse_task_status(nil), do: nil
  defp parse_task_status("pending"), do: :pending
  defp parse_task_status("running"), do: :running
  defp parse_task_status("completed"), do: :completed
  defp parse_task_status("failed"), do: :failed
  defp parse_task_status("cancelled"), do: :cancelled
  defp parse_task_status(_), do: nil

  defp parse_priority(nil), do: nil
  defp parse_priority("critical"), do: :critical
  defp parse_priority("high"), do: :high
  defp parse_priority("medium"), do: :medium
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: nil

  defp parse_provenance(nil), do: :built_in
  defp parse_provenance("built_in"), do: :built_in
  defp parse_provenance("remote"), do: :remote
  defp parse_provenance("mcp"), do: :mcp
  defp parse_provenance("custom"), do: :custom
  defp parse_provenance(_), do: :custom

  defp maybe_add(list, _key, nil), do: list
  defp maybe_add(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_add_kw(list, _key, nil), do: list
  defp maybe_add_kw(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, key, val) when is_integer(val), do: Map.put(map, key, val)
  defp maybe_put_int(map, _key, _), do: map
end
