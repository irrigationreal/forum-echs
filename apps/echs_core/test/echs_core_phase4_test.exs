defmodule EchsCore.Phase4Test do
  use ExUnit.Case, async: true

  alias EchsCore.PlanGraph.{Plan, Task}
  alias EchsCore.AgentTeam.{Manager, AutonomyLoop}
  alias EchsCore.Checkpoint.Engine

  # =====================================================================
  # PlanGraph.Task tests
  # =====================================================================

  describe "PlanGraph.Task" do
    test "creates a task with defaults" do
      task = Task.new(title: "Test task", description: "Do something")
      assert String.starts_with?(task.id, "task_")
      assert task.title == "Test task"
      assert task.status == :pending
      assert task.priority == :medium
      assert task.deps == []
    end

    test "deps_satisfied? checks completed deps" do
      t1 = Task.new(id: "t1", status: :completed)
      t2 = Task.new(id: "t2", deps: ["t1"])

      tasks = %{"t1" => t1, "t2" => t2}
      assert Task.deps_satisfied?(t2, tasks)
    end

    test "deps_satisfied? fails for non-completed deps" do
      t1 = Task.new(id: "t1", status: :running)
      t2 = Task.new(id: "t2", deps: ["t1"])

      tasks = %{"t1" => t1, "t2" => t2}
      refute Task.deps_satisfied?(t2, tasks)
    end

    test "terminal? checks for terminal states" do
      assert Task.terminal?(%Task{status: :completed})
      assert Task.terminal?(%Task{status: :failed})
      assert Task.terminal?(%Task{status: :cancelled})
      refute Task.terminal?(%Task{status: :pending})
      refute Task.terminal?(%Task{status: :running})
    end

    test "runnable? checks pending + deps" do
      t1 = Task.new(id: "t1", status: :completed)
      t2 = Task.new(id: "t2", deps: ["t1"], status: :pending)

      tasks = %{"t1" => t1, "t2" => t2}
      assert Task.runnable?(t2, tasks)
    end
  end

  # =====================================================================
  # PlanGraph.Plan tests
  # =====================================================================

  describe "PlanGraph.Plan" do
    test "creates a plan and adds tasks" do
      plan =
        Plan.new("Build a web app")
        |> Plan.add_task(Task.new(id: "t1", title: "Setup project"))
        |> Plan.add_task(Task.new(id: "t2", title: "Write code", deps: ["t1"]))
        |> Plan.add_task(Task.new(id: "t3", title: "Test", deps: ["t2"]))

      assert plan.goal == "Build a web app"
      assert map_size(plan.tasks) == 3
      assert plan.task_order == ["t1", "t2", "t3"]
    end

    test "runnable_tasks returns tasks with satisfied deps" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", title: "First", status: :completed))
        |> Plan.add_task(Task.new(id: "t2", title: "Second", deps: ["t1"]))
        |> Plan.add_task(Task.new(id: "t3", title: "Third", deps: ["t2"]))

      runnable = Plan.runnable_tasks(plan)
      assert length(runnable) == 1
      assert hd(runnable).id == "t2"
    end

    test "runnable_tasks respects priority ordering" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", title: "Low", priority: :low))
        |> Plan.add_task(Task.new(id: "t2", title: "High", priority: :high))
        |> Plan.add_task(Task.new(id: "t3", title: "Critical", priority: :critical))

      runnable = Plan.runnable_tasks(plan)
      priorities = Enum.map(runnable, & &1.priority)
      assert priorities == [:critical, :high, :low]
    end

    test "update_task changes task status" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", title: "Task"))

      {:ok, plan} = Plan.update_task(plan, "t1", status: :completed, result: "done")
      assert plan.tasks["t1"].status == :completed
      assert plan.tasks["t1"].result == "done"
    end

    test "all_terminal? checks all tasks" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", status: :completed))
        |> Plan.add_task(Task.new(id: "t2", status: :completed))

      assert Plan.all_terminal?(plan)
    end

    test "status_counts returns counts by status" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", status: :completed))
        |> Plan.add_task(Task.new(id: "t2", status: :pending))
        |> Plan.add_task(Task.new(id: "t3", status: :pending))

      counts = Plan.status_counts(plan)
      assert counts[:completed] == 1
      assert counts[:pending] == 2
    end
  end

  # =====================================================================
  # AgentTeam.Manager tests
  # =====================================================================

  describe "AgentTeam.Manager" do
    setup do
      {:ok, manager} = Manager.start_link(conversation_id: "conv_test")
      {:ok, manager: manager}
    end

    test "spawns an agent", %{manager: manager} do
      {:ok, agent_id} = Manager.spawn_agent(manager, role: "worker")

      assert String.starts_with?(agent_id, "agt_")

      {:ok, config} = Manager.get_agent(manager, agent_id)
      assert config.role == "worker"
      assert config.status == :idle
      assert config.model == "gpt-5.3-codex"  # worker default
    end

    test "spawns with custom model", %{manager: manager} do
      {:ok, agent_id} = Manager.spawn_agent(manager, role: "explorer", model: "gpt-4o")

      {:ok, config} = Manager.get_agent(manager, agent_id)
      assert config.model == "gpt-4o"
    end

    test "lists agents", %{manager: manager} do
      Manager.spawn_agent(manager, role: "worker")
      Manager.spawn_agent(manager, role: "explorer")

      agents = Manager.list_agents(manager)
      assert length(agents) == 2
    end

    test "sends inter-agent messages", %{manager: manager} do
      {:ok, a1} = Manager.spawn_agent(manager, role: "orchestrator")
      {:ok, a2} = Manager.spawn_agent(manager, role: "worker")

      :ok = Manager.send_message(manager, a1, a2, "please do task X")
    end

    test "terminates an agent", %{manager: manager} do
      {:ok, agent_id} = Manager.spawn_agent(manager, role: "worker")
      :ok = Manager.terminate_agent(manager, agent_id, "done")

      {:ok, config} = Manager.get_agent(manager, agent_id)
      assert config.status == :terminated
    end

    test "budget tracking", %{manager: manager} do
      {:ok, agent_id} = Manager.spawn_agent(manager,
        role: "worker",
        budget: %{max_tokens: 1000}
      )

      :ok = Manager.record_usage(manager, agent_id, 300, 200)
      refute Manager.budget_exhausted?(manager, agent_id)

      {:error, :budget_exhausted} = Manager.record_usage(manager, agent_id, 400, 200)
      assert Manager.budget_exhausted?(manager, agent_id)
    end

    test "role_defaults returns expected values" do
      assert Manager.role_defaults("worker").model == "gpt-5.3-codex"
      assert Manager.role_defaults("explorer").model == "gpt-5.2"
      assert Manager.role_defaults("orchestrator").reasoning == "high"
    end
  end

  # =====================================================================
  # AutonomyLoop tests
  # =====================================================================

  describe "AutonomyLoop" do
    test "lifecycle: goal -> plan -> execute -> goal_met" do
      loop = AutonomyLoop.new()
      assert loop.status == :idle

      loop = AutonomyLoop.set_goal(loop, "Build a feature")
      assert loop.status == :goal_received

      plan =
        Plan.new("Build a feature")
        |> Plan.add_task(Task.new(id: "t1", title: "Code it"))
        |> Plan.add_task(Task.new(id: "t2", title: "Test it", deps: ["t1"]))

      loop = AutonomyLoop.set_plan(loop, plan)
      assert loop.status == :executing

      # Get next tasks
      tasks = AutonomyLoop.next_tasks(loop)
      assert length(tasks) == 1
      assert hd(tasks).id == "t1"

      # Complete t1
      loop = AutonomyLoop.complete_task(loop, "t1", "done")
      assert loop.status == :executing

      # Now t2 is runnable
      tasks = AutonomyLoop.next_tasks(loop)
      assert length(tasks) == 1
      assert hd(tasks).id == "t2"

      # Complete t2
      loop = AutonomyLoop.complete_task(loop, "t2", "all tests pass")
      assert loop.status == :goal_met
    end

    test "stops on budget exhaustion" do
      loop = AutonomyLoop.new()
      loop = AutonomyLoop.set_goal(loop, "test")
      loop = AutonomyLoop.stop(loop, "budget_exhausted")

      assert loop.status == :stopped
      assert loop.stop_reason == "budget_exhausted"
      assert AutonomyLoop.terminal?(loop)
    end

    test "enters reviewing when tasks fail" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", title: "Might fail"))

      loop =
        AutonomyLoop.new()
        |> AutonomyLoop.set_goal("test")
        |> AutonomyLoop.set_plan(plan)

      loop = AutonomyLoop.fail_task(loop, "t1", "compilation error")
      assert loop.status == :reviewing
    end

    test "stop_on_first_failure stops immediately" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", title: "Fail"))

      loop =
        AutonomyLoop.new(stop_on_first_failure: true)
        |> AutonomyLoop.set_goal("test")
        |> AutonomyLoop.set_plan(plan)

      loop = AutonomyLoop.fail_task(loop, "t1", "error")
      assert loop.status == :stopped
    end

    test "summary returns state overview" do
      plan =
        Plan.new("test")
        |> Plan.add_task(Task.new(id: "t1", status: :completed))
        |> Plan.add_task(Task.new(id: "t2", status: :pending))

      loop =
        AutonomyLoop.new()
        |> AutonomyLoop.set_goal("build it")
        |> AutonomyLoop.set_plan(plan)

      summary = AutonomyLoop.summary(loop)
      assert summary.status == :executing
      assert summary.goal == "build it"
      assert summary.task_counts[:completed] == 1
      assert summary.task_counts[:pending] == 1
    end
  end

  # =====================================================================
  # Checkpoint.Engine tests
  # =====================================================================

  describe "Checkpoint.Engine" do
    @moduletag :tmp_dir

    @tag :tmp_dir
    test "creates and restores a checkpoint", %{tmp_dir: tmp_dir} do
      # Setup workspace
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "hello.txt"), "hello world")
      File.write!(Path.join(workspace, "data.json"), ~s({"key": "value"}))
      File.mkdir_p!(Path.join(workspace, "src"))
      File.write!(Path.join(workspace, "src/main.ex"), "defmodule Main do\nend\n")

      store = Path.join(tmp_dir, "checkpoints")

      # Create checkpoint
      {:ok, checkpoint} = Engine.create(
        workspace_root: workspace,
        store_dir: store,
        trigger: :manual
      )

      assert String.starts_with?(checkpoint.checkpoint_id, "chk_")
      assert length(checkpoint.files) == 3
      assert checkpoint.total_bytes > 0

      # Modify workspace
      File.write!(Path.join(workspace, "hello.txt"), "modified!")
      File.write!(Path.join(workspace, "new_file.txt"), "new")
      File.rm!(Path.join(workspace, "data.json"))

      # Restore checkpoint
      {:ok, result} = Engine.restore(
        store_dir: store,
        checkpoint_id: checkpoint.checkpoint_id,
        target_dir: workspace
      )

      assert result.files_restored == 3

      # Verify restoration
      assert File.read!(Path.join(workspace, "hello.txt")) == "hello world"
      assert File.read!(Path.join(workspace, "data.json")) == ~s({"key": "value"})
      assert File.read!(Path.join(workspace, "src/main.ex")) == "defmodule Main do\nend\n"
    end

    @tag :tmp_dir
    test "dry_run shows diff without applying", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "file.txt"), "original")

      store = Path.join(tmp_dir, "checkpoints")
      {:ok, checkpoint} = Engine.create(workspace_root: workspace, store_dir: store)

      # Modify
      File.write!(Path.join(workspace, "file.txt"), "changed")

      {:ok, result} = Engine.restore(
        store_dir: store,
        checkpoint_id: checkpoint.checkpoint_id,
        target_dir: workspace,
        dry_run: true
      )

      assert result.diff.modified == ["file.txt"]
      # Verify file wasn't actually restored
      assert File.read!(Path.join(workspace, "file.txt")) == "changed"
    end

    @tag :tmp_dir
    test "list returns all checkpoints", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "f.txt"), "content")

      store = Path.join(tmp_dir, "checkpoints")
      Engine.create(workspace_root: workspace, store_dir: store)
      Engine.create(workspace_root: workspace, store_dir: store)

      checkpoints = Engine.list(store)
      assert length(checkpoints) == 2
    end

    test "should_auto_checkpoint? detects side-effectful tools" do
      assert Engine.should_auto_checkpoint?(%{side_effects: true, idempotent: false})
      refute Engine.should_auto_checkpoint?(%{side_effects: false, idempotent: true})
      refute Engine.should_auto_checkpoint?(%{side_effects: true, idempotent: true})
    end
  end
end
