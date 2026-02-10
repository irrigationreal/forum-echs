defmodule EchsCore.Phase5Test do
  use ExUnit.Case, async: true

  # =====================================================================
  # Memory.Memory tests (bd-0041)
  # =====================================================================

  alias EchsCore.Memory.Memory

  describe "Memory.Memory" do
    test "creates a memory with defaults" do
      mem = Memory.new(content: "Elixir uses pattern matching")
      assert String.starts_with?(mem.memory_id, "mem_")
      assert mem.content == "Elixir uses pattern matching"
      assert mem.memory_type == :semantic
      assert mem.confidence == 0.5
      assert mem.privacy == :internal
      assert mem.tags == []
      assert mem.expires_at_ms == nil
    end

    test "creates a memory with all fields" do
      mem = Memory.new(
        memory_type: :procedural,
        content: "To deploy, run mix release",
        tags: ["deployment", "elixir"],
        confidence: 0.9,
        privacy: :public,
        conversation_id: "conv_123",
        source_rune_ids: ["rune_abc"],
        expires_at_ms: System.system_time(:millisecond) + 86_400_000
      )

      assert mem.memory_type == :procedural
      assert mem.confidence == 0.9
      assert mem.privacy == :public
      assert "deployment" in mem.tags
    end

    test "expired? checks expiry" do
      past = System.system_time(:millisecond) - 1000
      mem = Memory.new(expires_at_ms: past)
      assert Memory.expired?(mem)

      future = System.system_time(:millisecond) + 100_000
      mem2 = Memory.new(expires_at_ms: future)
      refute Memory.expired?(mem2)

      mem3 = Memory.new()
      refute Memory.expired?(mem3)
    end

    test "visible? respects privacy levels" do
      public = Memory.new(privacy: :public)
      internal = Memory.new(privacy: :internal)
      secret = Memory.new(privacy: :secret)

      assert Memory.visible?(public, :public)
      assert Memory.visible?(public, :internal)
      assert Memory.visible?(public, :secret)

      refute Memory.visible?(internal, :public)
      assert Memory.visible?(internal, :internal)
      assert Memory.visible?(internal, :secret)

      refute Memory.visible?(secret, :public)
      refute Memory.visible?(secret, :internal)
      assert Memory.visible?(secret, :secret)
    end

    test "update_confidence clamps to 0.0-1.0" do
      mem = Memory.new()
      assert Memory.update_confidence(mem, 1.5).confidence == 1.0
      assert Memory.update_confidence(mem, -0.5).confidence == 0.0
      assert Memory.update_confidence(mem, 0.75).confidence == 0.75
    end

    test "add_tags deduplicates" do
      mem = Memory.new(tags: ["a", "b"])
      mem = Memory.add_tags(mem, ["b", "c"])
      assert mem.tags == ["a", "b", "c"]
    end

    test "to_map/from_map round-trip" do
      mem = Memory.new(
        memory_type: :decision,
        content: "Chose Phoenix over Express",
        tags: ["architecture"],
        confidence: 0.8,
        privacy: :public
      )

      map = Memory.to_map(mem)
      restored = Memory.from_map(map)

      assert restored.memory_id == mem.memory_id
      assert restored.memory_type == :decision
      assert restored.content == mem.content
      assert restored.tags == mem.tags
      assert restored.confidence == mem.confidence
      assert restored.privacy == :public
    end
  end

  # =====================================================================
  # Memory.Store tests (bd-0041)
  # =====================================================================

  alias EchsCore.Memory.Store

  describe "Memory.Store" do
    setup do
      {:ok, store} = Store.start_link()
      {:ok, store: store}
    end

    test "put and get a memory", %{store: store} do
      mem = Memory.new(content: "test memory")
      :ok = Store.put(store, mem)

      {:ok, retrieved} = Store.get(store, mem.memory_id)
      assert retrieved.content == "test memory"
    end

    test "get returns not_found for unknown ID", %{store: store} do
      assert {:error, :not_found} = Store.get(store, "mem_nonexistent")
    end

    test "delete removes a memory", %{store: store} do
      mem = Memory.new(content: "to delete")
      Store.put(store, mem)
      Store.delete(store, mem.memory_id)
      assert {:error, :not_found} = Store.get(store, mem.memory_id)
    end

    test "update modifies a memory", %{store: store} do
      mem = Memory.new(content: "original")
      Store.put(store, mem)

      {:ok, updated} = Store.update(store, mem.memory_id, content: "modified", confidence: 0.9)
      assert updated.content == "modified"
      assert updated.confidence == 0.9
    end

    test "query_by_tags returns matching memories", %{store: store} do
      Store.put(store, Memory.new(content: "elixir stuff", tags: ["elixir", "programming"]))
      Store.put(store, Memory.new(content: "python stuff", tags: ["python", "programming"]))
      Store.put(store, Memory.new(content: "cooking", tags: ["food"]))

      results = Store.query_by_tags(store, ["programming"])
      assert length(results) == 2

      results = Store.query_by_tags(store, ["elixir", "programming"])
      assert length(results) == 1
      assert hd(results).content == "elixir stuff"
    end

    test "query_by_type filters by type", %{store: store} do
      Store.put(store, Memory.new(content: "fact", memory_type: :semantic))
      Store.put(store, Memory.new(content: "event", memory_type: :episodic))
      Store.put(store, Memory.new(content: "howto", memory_type: :procedural))

      results = Store.query_by_type(store, :semantic)
      assert length(results) == 1
      assert hd(results).content == "fact"
    end

    test "query_by_conversation scopes to conversation", %{store: store} do
      Store.put(store, Memory.new(content: "conv1 mem", conversation_id: "conv_1"))
      Store.put(store, Memory.new(content: "conv2 mem", conversation_id: "conv_2"))
      Store.put(store, Memory.new(content: "global mem"))

      results = Store.query_by_conversation(store, "conv_1")
      assert length(results) == 1
      assert hd(results).content == "conv1 mem"
    end

    test "search finds content matches", %{store: store} do
      Store.put(store, Memory.new(content: "Elixir uses GenServer for state"))
      Store.put(store, Memory.new(content: "Python has asyncio"))
      Store.put(store, Memory.new(content: "GenServer is an OTP behaviour"))

      results = Store.search(store, "GenServer")
      assert length(results) == 2
    end

    test "list respects privacy filter", %{store: store} do
      Store.put(store, Memory.new(content: "public", privacy: :public))
      Store.put(store, Memory.new(content: "internal", privacy: :internal))
      Store.put(store, Memory.new(content: "secret", privacy: :secret))

      public = Store.list(store, privacy: :public)
      assert length(public) == 1

      internal = Store.list(store, privacy: :internal)
      assert length(internal) == 2

      secret = Store.list(store, privacy: :secret)
      assert length(secret) == 3
    end

    test "list respects min_confidence", %{store: store} do
      Store.put(store, Memory.new(content: "low", confidence: 0.2))
      Store.put(store, Memory.new(content: "high", confidence: 0.9))

      results = Store.list(store, min_confidence: 0.5)
      assert length(results) == 1
      assert hd(results).content == "high"
    end

    test "sweep_expired removes old memories", %{store: store} do
      past = System.system_time(:millisecond) - 1000
      Store.put(store, Memory.new(content: "expired", expires_at_ms: past))
      Store.put(store, Memory.new(content: "valid"))

      count = Store.sweep_expired(store)
      assert count == 1

      results = Store.list(store)
      assert length(results) == 1
      assert hd(results).content == "valid"
    end

    test "export and import round-trip", %{store: store} do
      Store.put(store, Memory.new(content: "mem1", tags: ["a"]))
      Store.put(store, Memory.new(content: "mem2", tags: ["b"]))

      exported = Store.export(store)
      assert length(exported) == 2

      {:ok, store2} = Store.start_link()
      Store.import_memories(store2, exported)

      results = Store.list(store2)
      assert length(results) == 2
    end
  end

  # =====================================================================
  # Memory.Retrieval tests (bd-0043)
  # =====================================================================

  alias EchsCore.Memory.Retrieval

  describe "Memory.Retrieval" do
    setup do
      {:ok, store} = Store.start_link()

      Store.put(store, Memory.new(
        content: "Elixir GenServer handles stateful processes",
        tags: ["elixir", "otp"],
        confidence: 0.9,
        memory_type: :semantic
      ))

      Store.put(store, Memory.new(
        content: "To deploy, use mix release and Docker",
        tags: ["deployment"],
        confidence: 0.8,
        memory_type: :procedural
      ))

      Store.put(store, Memory.new(
        content: "We decided to use PostgreSQL for the database",
        tags: ["architecture", "database"],
        confidence: 0.95,
        memory_type: :decision
      ))

      Store.put(store, Memory.new(
        content: "Unrelated content about cooking recipes",
        tags: ["food"],
        confidence: 0.3,
        memory_type: :episodic
      ))

      {:ok, store: store}
    end

    test "retrieve returns relevant memories ranked by score", %{store: store} do
      result = Retrieval.retrieve(store, "GenServer elixir OTP")
      assert result.total_found >= 1
      assert length(result.memories) >= 1
      assert hd(result.memories).content =~ "GenServer"
    end

    test "retrieve respects max_memories limit", %{store: store} do
      result = Retrieval.retrieve(store, "elixir deploy database", %{max_memories: 1})
      assert length(result.memories) <= 1
    end

    test "retrieve respects min_confidence", %{store: store} do
      result = Retrieval.retrieve(store, "cooking recipes", %{min_confidence: 0.5})
      # Low confidence cooking memory should be filtered out
      assert Enum.all?(result.memories, &(&1.confidence >= 0.5))
    end

    test "retrieve filters by memory type", %{store: store} do
      result = Retrieval.retrieve(store, "deploy release", %{memory_types: [:procedural]})
      assert Enum.all?(result.memories, &(&1.memory_type == :procedural))
    end

    test "build_context_block generates XML-like block", %{store: store} do
      result = Retrieval.retrieve(store, "GenServer elixir")
      block = Retrieval.build_context_block(result)

      assert block =~ "<memory-context"
      assert block =~ "</memory-context>"
      assert block =~ "memories="
    end

    test "build_context_block returns empty for no memories" do
      block = Retrieval.build_context_block(%{memories: [], tokens_used: 0, truncated: false})
      assert block == ""
    end

    test "retrieve_for_task uses task fields", %{store: store} do
      task = %{title: "Deploy the application", description: "Use Docker and mix release"}
      result = Retrieval.retrieve_for_task(store, task)
      assert result.total_found >= 1
    end
  end

  # =====================================================================
  # ToolSystem.Sandbox tests (bd-0031)
  # =====================================================================

  alias EchsCore.ToolSystem.Sandbox

  describe "ToolSystem.Sandbox" do
    setup do
      sandbox = Sandbox.new("/workspace/project", denied_paths: [".env", ".git/", "secrets/"])
      {:ok, sandbox: sandbox}
    end

    test "validate_path allows paths within workspace", %{sandbox: sandbox} do
      assert {:ok, _} = Sandbox.validate_path(sandbox, "src/main.ex")
      assert {:ok, _} = Sandbox.validate_path(sandbox, "lib/app/module.ex")
    end

    test "validate_path blocks traversal", %{sandbox: sandbox} do
      assert {:error, msg} = Sandbox.validate_path(sandbox, "../../etc/passwd")
      assert msg =~ "traversal"
    end

    test "validate_path blocks denied patterns", %{sandbox: sandbox} do
      assert {:error, msg} = Sandbox.validate_path(sandbox, ".env")
      assert msg =~ "denied"

      assert {:error, _} = Sandbox.validate_path(sandbox, ".git/config")
      assert {:error, _} = Sandbox.validate_path(sandbox, "secrets/api_key.txt")
    end

    test "validate_path allows absolute paths within workspace", %{sandbox: sandbox} do
      assert {:ok, _} = Sandbox.validate_path(sandbox, "/workspace/project/src/file.ex")
    end

    test "validate_path blocks absolute paths outside workspace", %{sandbox: sandbox} do
      assert {:error, _} = Sandbox.validate_path(sandbox, "/etc/passwd")
      assert {:error, _} = Sandbox.validate_path(sandbox, "/home/user/.ssh/id_rsa")
    end

    test "validate_network blocks by default" do
      sandbox = Sandbox.new("/workspace")
      assert {:error, _} = Sandbox.validate_network(sandbox, "evil.com")
    end

    test "validate_network allows whitelisted hosts" do
      sandbox = Sandbox.new("/workspace", network_allowlist: ["api.github.com", "*.npmjs.org"])
      assert :ok = Sandbox.validate_network(sandbox, "api.github.com")
      assert :ok = Sandbox.validate_network(sandbox, "registry.npmjs.org")
      assert {:error, _} = Sandbox.validate_network(sandbox, "evil.com")
    end

    test "filter_env only includes allowed vars" do
      sandbox = Sandbox.new("/workspace", env_allowlist: ["PATH", "HOME"])
      filtered = Sandbox.filter_env(sandbox)
      keys = Enum.map(filtered, fn {k, _} -> k end)
      assert Enum.all?(keys, &(&1 in ["PATH", "HOME"]))
    end

    test "enforce_output_limit truncates long output" do
      sandbox = Sandbox.new("/workspace", max_output_bytes: 100)
      long_output = String.duplicate("x", 200)
      {output, truncated} = Sandbox.enforce_output_limit(sandbox, long_output)
      assert truncated
      assert byte_size(output) < 200
      assert output =~ "truncated"
    end

    test "enforce_output_limit passes short output" do
      sandbox = Sandbox.new("/workspace")
      {output, truncated} = Sandbox.enforce_output_limit(sandbox, "short")
      refute truncated
      assert output == "short"
    end

    test "validate_args checks path-like keys", %{sandbox: sandbox} do
      assert {:ok, _} = Sandbox.validate_args(sandbox, %{"path" => "src/main.ex"})
      assert {:error, _} = Sandbox.validate_args(sandbox, %{"file_path" => "../../etc/passwd"})
    end

    test "should_sandbox? checks tool spec" do
      assert Sandbox.should_sandbox?(%{side_effects: true, idempotent: false})
      assert Sandbox.should_sandbox?(%{side_effects: true, idempotent: true})
      refute Sandbox.should_sandbox?(%{side_effects: false, idempotent: true})
    end
  end

  # =====================================================================
  # Checkpoint.Rewind tests (bd-0047)
  # =====================================================================

  alias EchsCore.Checkpoint.{Engine, Rewind}

  describe "Checkpoint.Rewind" do
    @moduletag :tmp_dir

    @tag :tmp_dir
    test "list_rewind_points returns checkpoints", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "f.txt"), "content")

      store = Path.join(tmp_dir, "checkpoints")
      Engine.create(workspace_root: workspace, store_dir: store)
      Engine.create(workspace_root: workspace, store_dir: store)

      points = Rewind.list_rewind_points(store)
      assert length(points) == 2
      assert hd(points).file_count == 1
    end

    @tag :tmp_dir
    test "dry_run shows what would change", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "hello.txt"), "original")

      store = Path.join(tmp_dir, "checkpoints")
      {:ok, checkpoint} = Engine.create(workspace_root: workspace, store_dir: store)

      File.write!(Path.join(workspace, "hello.txt"), "modified")

      {:ok, result} = Rewind.rewind(
        store_dir: store,
        checkpoint_id: checkpoint.checkpoint_id,
        workspace_root: workspace,
        runelog_dir: Path.join(tmp_dir, "runelogs"),
        mode: :workspace,
        dry_run: true
      )

      assert result.diff != nil
      # File wasn't actually restored
      assert File.read!(Path.join(workspace, "hello.txt")) == "modified"
    end

    @tag :tmp_dir
    test "workspace rewind restores files", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "hello.txt"), "original")

      store = Path.join(tmp_dir, "checkpoints")
      {:ok, checkpoint} = Engine.create(workspace_root: workspace, store_dir: store)

      File.write!(Path.join(workspace, "hello.txt"), "changed!")

      {:ok, result} = Rewind.rewind(
        store_dir: store,
        checkpoint_id: checkpoint.checkpoint_id,
        workspace_root: workspace,
        runelog_dir: Path.join(tmp_dir, "runelogs"),
        mode: :workspace,
        create_safety_checkpoint: false
      )

      assert result.mode == :workspace
      assert File.read!(Path.join(workspace, "hello.txt")) == "original"
    end

    @tag :tmp_dir
    test "creates safety checkpoint before rewind", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "f.txt"), "v1")

      store = Path.join(tmp_dir, "checkpoints")
      {:ok, checkpoint} = Engine.create(workspace_root: workspace, store_dir: store)

      File.write!(Path.join(workspace, "f.txt"), "v2")

      {:ok, result} = Rewind.rewind(
        store_dir: store,
        checkpoint_id: checkpoint.checkpoint_id,
        workspace_root: workspace,
        runelog_dir: Path.join(tmp_dir, "runelogs"),
        mode: :workspace,
        create_safety_checkpoint: true
      )

      assert result.safety_checkpoint_id != nil
      # Original checkpoint + safety checkpoint
      all = Engine.list(store)
      assert length(all) >= 2
    end

    @tag :tmp_dir
    test "find_pre_tool_checkpoint finds linked checkpoint", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "f.txt"), "x")

      store = Path.join(tmp_dir, "checkpoints")
      {:ok, _} = Engine.create(
        workspace_root: workspace,
        store_dir: store,
        linked_call_id: "call_abc"
      )

      {:ok, found} = Rewind.find_pre_tool_checkpoint(store, "call_abc")
      assert found["linked_call_id"] == "call_abc"

      assert {:error, :not_found} = Rewind.find_pre_tool_checkpoint(store, "call_nonexistent")
    end
  end

  # =====================================================================
  # ToolSystem.Runner tests (bd-0028)
  # =====================================================================

  alias EchsCore.ToolSystem.Runner

  describe "ToolSystem.Runner" do
    test "in_process runner executes function" do
      result = Runner.run(:in_process, {Enum, :sum, [[1, 2, 3]]})
      assert result.status == :ok
      assert result.stdout =~ "6"
      assert result.duration_ms >= 0
    end

    test "in_process runner handles errors" do
      result = Runner.run(:in_process, {Kernel, :div, [1, 0]})
      assert result.status == :error
      assert result.stderr =~ "ArithmeticError" or result.stderr =~ "bad argument"
    end

    test "os_command runner executes commands" do
      result = Runner.run(:os_command, {"echo", ["hello"]})
      assert result.status == :ok
      assert result.stdout =~ "hello"
      assert result.exit_code == 0
    end

    test "os_command runner reports failures" do
      result = Runner.run(:os_command, {"false", []})
      assert result.status == :error
      assert result.exit_code != 0
    end

    test "runner_for_spec selects correct type" do
      assert Runner.runner_for_spec(%{runner: :os_command}) == :os_command
      assert Runner.runner_for_spec(%{type: "function"}) == :in_process
      assert Runner.runner_for_spec(%{type: "shell"}) == :os_command
      assert Runner.runner_for_spec(%{}) == :in_process
    end

    test "output truncation works" do
      result = Runner.run(:in_process, {String, :duplicate, ["x", 2_000_000]}, %{max_output_bytes: 1000})
      assert result.truncated
      assert byte_size(result.stdout) < 2_000_000
    end

    test "pty runner returns not implemented" do
      result = Runner.run(:pty, nil)
      assert result.status == :error
      assert result.stderr =~ "not yet implemented"
    end
  end

  # =====================================================================
  # AgentTeam.Archetypes tests (bd-0035)
  # =====================================================================

  alias EchsCore.AgentTeam.Archetypes

  describe "AgentTeam.Archetypes" do
    test "get returns known archetypes" do
      {:ok, arch} = Archetypes.get("orchestrator")
      assert arch.model == "gpt-5.2"
      assert arch.reasoning == "high"
      assert "spawn_agent" in arch.tool_access
    end

    test "get returns error for unknown role" do
      assert {:error, :unknown_role} = Archetypes.get("unknown_role")
    end

    test "roles returns all available roles" do
      roles = Archetypes.roles()
      assert "orchestrator" in roles
      assert "worker" in roles
      assert "explorer" in roles
      assert "critic" in roles
      assert "summarizer" in roles
      assert "monitor" in roles
    end

    test "system_prompt returns prompt for known role" do
      prompt = Archetypes.system_prompt("worker")
      assert prompt =~ "worker agent"
    end

    test "can_access_tool? checks role permissions" do
      assert Archetypes.can_access_tool?("worker", "read_file")
      assert Archetypes.can_access_tool?("worker", "write_file")
      refute Archetypes.can_access_tool?("explorer", "write_file")
      assert Archetypes.can_access_tool?("explorer", "search")
    end

    test "budget_defaults returns limits" do
      budget = Archetypes.budget_defaults("worker")
      assert budget.max_tokens == 50_000
      assert budget.max_tool_calls == 30
    end
  end

  # =====================================================================
  # AgentTeam.Critic tests (bd-0038)
  # =====================================================================

  alias EchsCore.AgentTeam.Critic

  describe "AgentTeam.Critic" do
    test "creates a critique with findings" do
      findings = [
        Critic.finding(:error, :correctness, "Null pointer",
          description: "Variable may be nil",
          file: "src/app.ex",
          line: 42),
        Critic.finding(:warning, :security, "SQL injection risk",
          description: "User input not sanitized"),
        Critic.finding(:suggestion, :style, "Consider using pattern matching")
      ]

      critique = Critic.new_critique(findings: findings, task_id: "t1")
      assert String.starts_with?(critique.critique_id, "crit_")
      assert length(critique.findings) == 3
      refute critique.pass  # has an error
      assert critique.summary =~ "error"
    end

    test "all_pass? with no errors" do
      findings = [
        Critic.finding(:warning, :style, "Minor issue"),
        Critic.finding(:suggestion, :performance, "Could be faster")
      ]
      assert Critic.all_pass?(findings)
    end

    test "severity_counts tallies correctly" do
      findings = [
        Critic.finding(:error, :correctness, "Bug"),
        Critic.finding(:error, :correctness, "Another bug"),
        Critic.finding(:warning, :style, "Style issue")
      ]

      counts = Critic.severity_counts(findings)
      assert counts[:error] == 2
      assert counts[:warning] == 1
    end

    test "filter_by_severity returns minimum severity and above" do
      findings = [
        Critic.finding(:error, :correctness, "Bug"),
        Critic.finding(:warning, :style, "Style"),
        Critic.finding(:suggestion, :performance, "Perf"),
        Critic.finding(:info, :completeness, "Info")
      ]

      result = Critic.filter_by_severity(findings, :warning)
      assert length(result) == 2
      severities = Enum.map(result, & &1.severity)
      assert :error in severities
      assert :warning in severities
    end

    test "findings_to_tasks generates tasks from errors/warnings" do
      findings = [
        Critic.finding(:error, :correctness, "Critical bug",
          suggested_fix: "Add nil check"),
        Critic.finding(:suggestion, :style, "Use pipe operator")
      ]

      tasks = Critic.findings_to_tasks(findings)
      assert length(tasks) == 1
      assert hd(tasks).title =~ "Critical bug"
      assert hd(tasks).priority == :high
    end
  end

  # =====================================================================
  # Hooks.Framework tests (bd-0039)
  # =====================================================================

  alias EchsCore.Hooks.Framework

  describe "Hooks.Framework" do
    setup do
      {:ok, hooks} = Framework.start_link()
      {:ok, hooks: hooks}
    end

    test "register and list hooks", %{hooks: hooks} do
      {:ok, _id} = Framework.register(hooks, :turn_completed, fn _ctx -> :ok end,
        description: "test hook")

      listed = Framework.list(hooks)
      assert length(listed) == 1
      assert hd(listed).trigger == :turn_completed
    end

    test "fire triggers registered hooks", %{hooks: hooks} do
      test_pid = self()
      {:ok, _id} = Framework.register(hooks, :after_tool_result,
        fn ctx -> send(test_pid, {:hook_fired, ctx}) end)

      results = Framework.fire(hooks, :after_tool_result, %{tool: "read_file"})
      assert length(results) == 1
      assert {_, :ok} = hd(results)

      assert_receive {:hook_fired, %{tool: "read_file"}}
    end

    test "disabled hooks are not fired", %{hooks: hooks} do
      {:ok, id} = Framework.register(hooks, :turn_completed, fn _ctx -> :ok end)
      Framework.set_enabled(hooks, id, false)

      results = Framework.fire(hooks, :turn_completed)
      assert results == []
    end

    test "unregister removes a hook", %{hooks: hooks} do
      {:ok, id} = Framework.register(hooks, :turn_completed, fn _ctx -> :ok end)
      Framework.unregister(hooks, id)

      listed = Framework.list(hooks)
      assert listed == []
    end

    test "fire respects priority ordering", %{hooks: hooks} do
      test_pid = self()
      {:ok, _} = Framework.register(hooks, :task_completed,
        fn _ctx -> send(test_pid, :second) end, priority: 200)
      {:ok, _} = Framework.register(hooks, :task_completed,
        fn _ctx -> send(test_pid, :first) end, priority: 100)

      Framework.fire(hooks, :task_completed)

      assert_receive :first
      assert_receive :second
    end

    test "list_for_trigger filters by trigger", %{hooks: hooks} do
      {:ok, _} = Framework.register(hooks, :turn_completed, fn _ -> :ok end)
      {:ok, _} = Framework.register(hooks, :file_changed, fn _ -> :ok end)

      turn_hooks = Framework.list_for_trigger(hooks, :turn_completed)
      assert length(turn_hooks) == 1
      assert hd(turn_hooks).trigger == :turn_completed
    end

    test "hook errors are caught and reported", %{hooks: hooks} do
      {:ok, _} = Framework.register(hooks, :turn_completed,
        fn _ctx -> raise "boom" end)

      results = Framework.fire(hooks, :turn_completed)
      assert length(results) == 1
      {_id, result} = hd(results)
      assert {:error, _} = result
    end
  end

  # =====================================================================
  # Observability.Tracing tests (bd-0055)
  # =====================================================================

  alias EchsCore.Observability.Tracing

  describe "Observability.Tracing" do
    test "start_span creates a root span" do
      span = Tracing.start_span("turn.execute", %{conversation_id: "conv_1"})
      assert String.starts_with?(span.trace_id, "trc_")
      assert String.starts_with?(span.span_id, "spn_")
      assert span.parent_span_id == nil
      assert span.status == :running
      assert span.name == "turn.execute"
    end

    test "start_child_span inherits trace_id" do
      parent = Tracing.start_span("parent")
      child = Tracing.start_child_span(parent, "child")

      assert child.trace_id == parent.trace_id
      assert child.parent_span_id == parent.span_id
      assert child.span_id != parent.span_id
    end

    test "end_span computes duration" do
      span = Tracing.start_span("test")
      Process.sleep(10)
      span = Tracing.end_span(span)

      assert span.status == :ok
      assert span.duration_ms >= 10
      assert span.end_ms != nil
    end

    test "end_span with error status" do
      span = Tracing.start_span("test")
      span = Tracing.end_span(span, :error)
      assert span.status == :error
    end

    test "add_event appends to span" do
      span = Tracing.start_span("test")
      span = Tracing.add_event(span, "tool.started", %{tool: "read_file"})
      span = Tracing.add_event(span, "tool.completed", %{tool: "read_file"})

      assert length(span.events) == 2
      assert hd(span.events).name == "tool.started"
    end

    test "add_metadata merges into span" do
      span = Tracing.start_span("test", %{key1: "val1"})
      span = Tracing.add_metadata(span, %{key2: "val2"})

      assert span.metadata.key1 == "val1"
      assert span.metadata.key2 == "val2"
    end

    test "correlation_id combines trace and span" do
      span = Tracing.start_span("test")
      cid = Tracing.correlation_id(span)
      assert cid =~ ":"
      assert cid =~ span.trace_id
      assert cid =~ span.span_id
    end

    test "to_log_entry formats span" do
      span = Tracing.start_span("test", %{conv: "c1"})
      span = Tracing.add_event(span, "evt")
      span = Tracing.end_span(span)

      entry = Tracing.to_log_entry(span)
      assert entry.name == "test"
      assert entry.event_count == 1
      assert entry.duration_ms >= 0
    end
  end

  # =====================================================================
  # Observability.GateSuite tests (bd-0058)
  # =====================================================================

  alias EchsCore.Observability.GateSuite

  describe "Observability.GateSuite" do
    test "all_gates returns known gates" do
      gates = GateSuite.all_gates()
      assert "replay_determinism" in gates
      assert "tool_terminality" in gates
      assert "event_ordering" in gates
      assert "checkpoint_integrity" in gates
      assert "perf_regression" in gates
    end

    test "run_all with no opts skips all gates" do
      result = GateSuite.run_all()
      assert result.skipped == length(GateSuite.all_gates())
      assert result.failed == 0
      assert result.passed == 0
    end

    @tag :tmp_dir
    test "checkpoint_integrity gate passes for valid store", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "f.txt"), "data")

      store = Path.join(tmp_dir, "store")
      Engine.create(workspace_root: workspace, store_dir: store)

      result = GateSuite.run_gate("checkpoint_integrity", store_dir: store)
      assert result.status == :pass
    end

    test "report formats results" do
      suite = %{
        results: [
          %{gate: "test_gate", status: :pass, message: "All good", duration_ms: 10, details: %{}}
        ],
        passed: 1,
        failed: 0,
        skipped: 0,
        total_duration_ms: 10
      }

      report = GateSuite.report(suite)
      assert report =~ "1 passed"
      assert report =~ "[PASS]"
      assert report =~ "test_gate"
    end
  end

  # =====================================================================
  # RemoteProvider tests (bd-0029)
  # =====================================================================

  alias EchsCore.ToolSystem.RemoteProvider

  describe "ToolSystem.RemoteProvider" do
    test "new creates a configuration" do
      config = RemoteProvider.new("https://api.example.com",
        timeout_ms: 5000,
        idempotency: true)

      assert config.base_url == "https://api.example.com"
      assert config.timeout_ms == 5000
      assert config.idempotency == true
    end

    test "new with auth config" do
      config = RemoteProvider.new("https://api.example.com",
        auth: %{type: :bearer, secret_ref: "MY_API_TOKEN"})

      assert config.auth.type == :bearer
      assert config.auth.secret_ref == "MY_API_TOKEN"
    end
  end
end
