defmodule EchsCore.ApiV2Test do
  use ExUnit.Case, async: true

  alias EchsCore.ApiV2.{Spec, Handlers}
  alias EchsCore.Memory.{Memory, Store}
  alias EchsCore.PlanGraph.{Plan, Task}
  alias EchsCore.AgentTeam.Manager

  # =====================================================================
  # Spec tests
  # =====================================================================

  describe "ApiV2.Spec" do
    test "openapi_spec returns valid structure" do
      spec = Spec.openapi_spec()
      assert spec["openapi"] == "3.1.0"
      assert spec["info"]["title"] == "ECHS API v2"
      assert spec["info"]["version"] == "2.0.0"
      assert is_map(spec["paths"])
      assert is_map(spec["components"])
    end

    test "endpoint_paths includes all expected groups" do
      paths = Spec.endpoint_paths()

      # Conversations
      assert "/v2/conversations" in paths
      assert "/v2/conversations/{conversation_id}" in paths

      # Messages
      assert "/v2/conversations/{conversation_id}/messages" in paths

      # Tools
      assert "/v2/conversations/{conversation_id}/tools" in paths

      # Checkpoints
      assert "/v2/conversations/{conversation_id}/checkpoints" in paths

      # Memory
      assert "/v2/conversations/{conversation_id}/memories" in paths

      # Plan
      assert "/v2/conversations/{conversation_id}/plan" in paths

      # Agents
      assert "/v2/conversations/{conversation_id}/agents" in paths

      # MCP
      assert "/v2/mcp/servers" in paths

      # Meta
      assert "/v2/health" in paths
      assert "/v2/models" in paths
    end

    test "spec includes schemas" do
      spec = Spec.openapi_spec()
      schemas = spec["components"]["schemas"]
      assert Map.has_key?(schemas, "Rune")
      assert Map.has_key?(schemas, "Memory")
      assert Map.has_key?(schemas, "Task")
      assert Map.has_key?(schemas, "Checkpoint")
    end
  end

  # =====================================================================
  # Memory handler tests
  # =====================================================================

  describe "Handlers - Memory" do
    setup do
      {:ok, store} = Store.start_link()

      Store.put(store, Memory.new(
        conversation_id: "conv_1",
        content: "Elixir GenServer",
        tags: ["elixir"],
        confidence: 0.9
      ))

      Store.put(store, Memory.new(
        conversation_id: "conv_1",
        content: "Phoenix Framework",
        tags: ["phoenix"],
        confidence: 0.8
      ))

      {:ok, store: store}
    end

    test "list_memories returns memories for conversation", %{store: store} do
      {status, body} = Handlers.list_memories(store, "conv_1", %{})
      assert status == 200
      assert body.count == 2
    end

    test "create_memory adds a memory", %{store: store} do
      {status, body} = Handlers.create_memory(store, "conv_1", %{
        "content" => "New knowledge",
        "type" => "semantic",
        "tags" => ["test"],
        "confidence" => 0.7
      })

      assert status == 201
      assert body.memory.content == "New knowledge"
      assert body.memory.conversation_id == "conv_1"
    end

    test "get_memory finds existing", %{store: store} do
      memories = Store.list(store)
      mem = hd(memories)

      {status, body} = Handlers.get_memory(store, mem.memory_id)
      assert status == 200
      assert body.memory.content == mem.content
    end

    test "get_memory returns 404 for unknown", %{store: store} do
      {status, _} = Handlers.get_memory(store, "mem_unknown")
      assert status == 404
    end

    test "update_memory modifies content", %{store: store} do
      memories = Store.list(store)
      mem = hd(memories)

      {status, body} = Handlers.update_memory(store, mem.memory_id, %{
        "content" => "Updated content",
        "confidence" => 0.95
      })

      assert status == 200
      assert body.memory.content == "Updated content"
    end

    test "delete_memory removes memory", %{store: store} do
      memories = Store.list(store)
      mem = hd(memories)

      {status, _} = Handlers.delete_memory(store, mem.memory_id)
      assert status == 200

      {status, _} = Handlers.get_memory(store, mem.memory_id)
      assert status == 404
    end

    test "search_memories finds relevant results", %{store: store} do
      {status, body} = Handlers.search_memories(store, "conv_1", %{
        "query" => "GenServer"
      })

      assert status == 200
      assert body.total_found >= 1
    end
  end

  # =====================================================================
  # Plan handler tests
  # =====================================================================

  describe "Handlers - Plan" do
    test "get_plan returns nil plan" do
      {status, body} = Handlers.get_plan(nil)
      assert status == 200
      assert body.plan == nil
    end

    test "get_plan returns plan details" do
      plan =
        Plan.new("Build a web app")
        |> Plan.add_task(Task.new(id: "t1", title: "Setup", status: :completed))
        |> Plan.add_task(Task.new(id: "t2", title: "Code", deps: ["t1"]))

      {status, body} = Handlers.get_plan(plan)
      assert status == 200
      assert body.plan.goal == "Build a web app"
      assert body.plan.task_count == 2
      assert body.plan.status_counts[:completed] == 1
    end

    test "update_task changes status" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", title: "Task"))

      {status, body} = Handlers.update_task(plan, "t1", %{"status" => "completed", "result" => "done"})
      assert status == 200
      assert body.task.status == :completed
    end

    test "update_task returns 404 for unknown" do
      plan = Plan.new("test")
      {status, _} = Handlers.update_task(plan, "nonexistent", %{"status" => "completed"})
      assert status == 404
    end
  end

  # =====================================================================
  # Agent handler tests
  # =====================================================================

  describe "Handlers - Agents" do
    setup do
      {:ok, manager} = Manager.start_link(conversation_id: "conv_test")
      {:ok, manager: manager}
    end

    test "list_agents returns empty initially", %{manager: manager} do
      {status, body} = Handlers.list_agents(manager)
      assert status == 200
      assert body.count == 0
    end

    test "spawn_agent creates an agent", %{manager: manager} do
      {status, body} = Handlers.spawn_agent(manager, %{"role" => "worker"})
      assert status == 201
      assert body.agent.role == "worker"
      assert body.agent.status == :idle
    end

    test "get_agent finds existing", %{manager: manager} do
      {201, %{agent: %{agent_id: id}}} = Handlers.spawn_agent(manager, %{"role" => "explorer"})
      {status, body} = Handlers.get_agent(manager, id)
      assert status == 200
      assert body.agent.role == "explorer"
    end

    test "get_agent returns 404 for unknown", %{manager: manager} do
      {status, _} = Handlers.get_agent(manager, "agt_unknown")
      assert status == 404
    end

    test "terminate_agent changes status", %{manager: manager} do
      {201, %{agent: %{agent_id: id}}} = Handlers.spawn_agent(manager, %{"role" => "worker"})
      {status, _} = Handlers.terminate_agent(manager, id)
      assert status == 200

      {200, body} = Handlers.get_agent(manager, id)
      assert body.agent.status == :terminated
    end

    test "spawn_agent with budget", %{manager: manager} do
      {status, body} = Handlers.spawn_agent(manager, %{
        "role" => "worker",
        "budget" => %{"max_tokens" => 5000}
      })
      assert status == 201
      assert body.agent.budget.max_tokens == 5000
    end
  end
end
