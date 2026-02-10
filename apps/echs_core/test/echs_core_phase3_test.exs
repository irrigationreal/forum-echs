defmodule EchsCore.Phase3Test do
  use ExUnit.Case, async: true

  alias EchsCore.ToolSystem.{ToolSpec, ToolRegistry, ToolRouter, PermissionPolicy}
  alias EchsCore.WebSocket.Handler
  alias EchsCore.Rune.Schema

  # =====================================================================
  # ToolSpec tests
  # =====================================================================

  describe "ToolSpec" do
    test "from_legacy creates spec with defaults" do
      legacy = %{
        "name" => "shell",
        "description" => "Execute shell command",
        "type" => "function",
        "parameters" => %{"type" => "object", "properties" => %{"cmd" => %{"type" => "string"}}}
      }

      spec = ToolSpec.from_legacy(legacy)
      assert spec.name == "shell"
      assert spec.description == "Execute shell command"
      assert spec.side_effects == true  # shell has side effects
      assert spec.idempotent == false
      assert spec.provenance == :built_in
      assert spec.enabled == true
      assert spec.timeout == 120_000
    end

    test "from_legacy infers read-only tools correctly" do
      spec = ToolSpec.from_legacy(%{"name" => "read_file"})
      assert spec.side_effects == false
      assert spec.idempotent == true
    end

    test "to_provider_format strips metadata" do
      spec = ToolSpec.from_legacy(%{"name" => "shell", "description" => "Run cmd"})
      provider = ToolSpec.to_provider_format(spec)

      assert provider["name"] == "shell"
      assert provider["description"] == "Run cmd"
      refute Map.has_key?(provider, "side_effects")
      refute Map.has_key?(provider, "provenance")
    end

    test "to_map includes all metadata" do
      spec = ToolSpec.from_legacy(%{"name" => "shell"})
      map = ToolSpec.to_map(spec)

      assert map["side_effects"] == true
      assert map["provenance"] == "built_in"
      assert map["enabled"] == true
      assert is_integer(map["timeout"])
    end
  end

  # =====================================================================
  # ToolRegistry tests
  # =====================================================================

  describe "ToolRegistry" do
    setup do
      tools = [
        %{"name" => "shell", "description" => "Shell command"},
        %{"name" => "read_file", "description" => "Read file"},
        %{"name" => "apply_patch", "description" => "Apply patch"}
      ]

      {:ok, registry} = ToolRegistry.start_link(conversation_id: "conv_test", tools: tools)
      {:ok, registry: registry}
    end

    test "lists initial tools", %{registry: registry} do
      tools = ToolRegistry.list(registry)
      assert length(tools) == 3
      names = Enum.map(tools, & &1.spec.name) |> Enum.sort()
      assert names == ["apply_patch", "read_file", "shell"]
    end

    test "registers a new tool", %{registry: registry} do
      spec = %{"name" => "custom_tool", "description" => "Custom", "provenance" => "custom"}
      :ok = ToolRegistry.register(registry, spec, fn _ -> :ok end)

      {:ok, entry} = ToolRegistry.lookup(registry, "custom_tool")
      assert entry.spec.name == "custom_tool"
      assert entry.spec.provenance == :custom
      assert entry.handler != nil
    end

    test "unregisters a tool", %{registry: registry} do
      :ok = ToolRegistry.unregister(registry, "shell")
      assert {:error, :not_found} = ToolRegistry.lookup(registry, "shell")
    end

    test "enables and disables tools", %{registry: registry} do
      :ok = ToolRegistry.disable(registry, "shell")

      # Disabled tool not in enabled-only list
      enabled = ToolRegistry.list(registry, enabled_only: true)
      names = Enum.map(enabled, & &1.spec.name)
      refute "shell" in names

      # But still in full list
      all = ToolRegistry.list(registry, enabled_only: false)
      names = Enum.map(all, & &1.spec.name)
      assert "shell" in names

      # Re-enable
      :ok = ToolRegistry.enable(registry, "shell")
      enabled = ToolRegistry.list(registry, enabled_only: true)
      names = Enum.map(enabled, & &1.spec.name)
      assert "shell" in names
    end

    test "provider_specs returns provider format", %{registry: registry} do
      specs = ToolRegistry.provider_specs(registry)
      assert is_list(specs)
      assert Enum.all?(specs, &is_map/1)
      assert Enum.all?(specs, &Map.has_key?(&1, "name"))
    end

    test "filters by provenance", %{registry: registry} do
      :ok = ToolRegistry.register(registry, %{"name" => "mcp_tool", "provenance" => "mcp"})

      mcp_tools = ToolRegistry.list(registry, provenance: :mcp)
      assert length(mcp_tools) == 1
      assert hd(mcp_tools).spec.name == "mcp_tool"
    end
  end

  # =====================================================================
  # ToolRouter tests
  # =====================================================================

  describe "ToolRouter" do
    setup do
      {:ok, router} = ToolRouter.start_link(conversation_id: "conv_test")
      {:ok, router: router}
    end

    test "records a call and assigns call_id", %{router: router} do
      {:ok, call_id} = ToolRouter.record_call(router, %{
        "tool_name" => "shell",
        "arguments" => %{"cmd" => "ls"}
      })

      assert String.starts_with?(call_id, "call_")

      {:ok, call_state} = ToolRouter.get_call(router, call_id)
      assert call_state.status == :pending
      assert call_state.tool_name == "shell"
    end

    test "records a result for a pending call", %{router: router} do
      {:ok, call_id} = ToolRouter.record_call(router, %{"tool_name" => "shell"})

      :ok = ToolRouter.record_result(router, call_id, %{
        "status" => "success",
        "output" => "file.txt"
      })

      {:ok, call_state} = ToolRouter.get_call(router, call_id)
      assert call_state.status == :terminal
    end

    test "rejects duplicate results (INV-TOOL-TERMINAL)", %{router: router} do
      {:ok, call_id} = ToolRouter.record_call(router, %{"tool_name" => "shell"})
      :ok = ToolRouter.record_result(router, call_id, %{"status" => "success"})

      assert {:error, :already_completed} =
               ToolRouter.record_result(router, call_id, %{"status" => "error"})
    end

    test "rejects result for unknown call (INV-TOOL-CALL-BEFORE-RESULT)", %{router: router} do
      assert {:error, :unknown_call} =
               ToolRouter.record_result(router, "nonexistent", %{"status" => "success"})
    end

    test "lists pending calls", %{router: router} do
      {:ok, _} = ToolRouter.record_call(router, %{"tool_name" => "shell"})
      {:ok, _} = ToolRouter.record_call(router, %{"tool_name" => "read_file"})

      pending = ToolRouter.pending_calls(router)
      assert length(pending) == 2
    end

    test "cancel removes from pending", %{router: router} do
      {:ok, call_id} = ToolRouter.record_call(router, %{"tool_name" => "shell"})
      :ok = ToolRouter.cancel(router, call_id)

      pending = ToolRouter.pending_calls(router)
      assert length(pending) == 0
    end

    test "builds call rune", %{} do
      rune = ToolRouter.build_call_rune("conv_1", "agt_1", "call_1", %{
        "tool_name" => "shell",
        "arguments" => %{"cmd" => "ls"}
      })

      assert rune.kind == "tool.call"
      assert rune.payload["call_id"] == "call_1"
      assert rune.payload["tool_name"] == "shell"
    end

    test "builds result rune", %{} do
      rune = ToolRouter.build_result_rune("conv_1", "agt_1", "call_1", %{
        "status" => "success",
        "output" => "done"
      })

      assert rune.kind == "tool.result"
      assert rune.payload["status"] == "success"
    end
  end

  # =====================================================================
  # PermissionPolicy tests
  # =====================================================================

  describe "PermissionPolicy" do
    test "default policy approves everything" do
      policy = PermissionPolicy.default_policy()
      spec = ToolSpec.from_legacy(%{"name" => "shell"})

      assert :approved = PermissionPolicy.evaluate(policy, spec)
    end

    test "auto mode approves read-only tools" do
      policy = %{PermissionPolicy.default_policy() | mode: :auto}
      spec = ToolSpec.from_legacy(%{"name" => "read_file"})

      assert :approved = PermissionPolicy.evaluate(policy, spec)
    end

    test "auto mode requires approval for side-effectful tools" do
      policy = %{PermissionPolicy.default_policy() | mode: :auto}
      spec = ToolSpec.from_legacy(%{"name" => "shell"})

      assert :needs_approval = PermissionPolicy.evaluate(policy, spec)
    end

    test "read_only mode denies side-effectful tools" do
      policy = %{PermissionPolicy.default_policy() | mode: :read_only}
      spec = ToolSpec.from_legacy(%{"name" => "apply_patch"})

      assert :denied = PermissionPolicy.evaluate(policy, spec)
    end

    test "read_only mode approves read-only tools" do
      policy = %{PermissionPolicy.default_policy() | mode: :read_only}
      spec = ToolSpec.from_legacy(%{"name" => "read_file"})

      assert :approved = PermissionPolicy.evaluate(policy, spec)
    end

    test "per-tool override always requires approval" do
      spec = %{ToolSpec.from_legacy(%{"name" => "shell"}) | requires_approval: :always}
      policy = PermissionPolicy.default_policy()

      assert :needs_approval = PermissionPolicy.evaluate(policy, spec)
    end

    test "per-tool override never requires approval" do
      spec = %{ToolSpec.from_legacy(%{"name" => "shell"}) | requires_approval: :never}
      policy = %{PermissionPolicy.default_policy() | mode: :auto}

      assert :approved = PermissionPolicy.evaluate(policy, spec)
    end

    test "policy-level per-tool override" do
      policy = %{PermissionPolicy.default_policy() |
        mode: :auto,
        per_tool_overrides: %{"shell" => :never}
      }
      spec = ToolSpec.from_legacy(%{"name" => "shell"})

      assert :approved = PermissionPolicy.evaluate(policy, spec)
    end

    test "path_allowed? enforces workspace root" do
      policy = %{PermissionPolicy.default_policy() | workspace_root: "/home/user/project"}

      assert PermissionPolicy.path_allowed?(policy, "/home/user/project/src/main.rs")
      refute PermissionPolicy.path_allowed?(policy, "/etc/passwd")
      refute PermissionPolicy.path_allowed?(policy, "/home/user/other/secret.key")
    end

    test "path_allowed? with nil workspace allows everything" do
      policy = PermissionPolicy.default_policy()
      assert PermissionPolicy.path_allowed?(policy, "/any/path")
    end

    test "network_allowed? with empty lists allows everything" do
      policy = PermissionPolicy.default_policy()
      assert PermissionPolicy.network_allowed?(policy, "example.com")
    end

    test "network_allowed? with denylist" do
      policy = %{PermissionPolicy.default_policy() | network_denylist: ["evil.com", "*.malware.net"]}

      refute PermissionPolicy.network_allowed?(policy, "evil.com")
      refute PermissionPolicy.network_allowed?(policy, "sub.malware.net")
      assert PermissionPolicy.network_allowed?(policy, "google.com")
    end
  end

  # =====================================================================
  # WebSocket Handler tests
  # =====================================================================

  describe "WebSocket.Handler" do
    setup do
      messages = :ets.new(:ws_messages, [:bag, :public])
      send_fn = fn msg -> :ets.insert(messages, {msg}); :ok end
      state = Handler.init(send_fn)
      {:ok, state: state, messages: messages}
    end

    defp sent_messages(messages) do
      :ets.tab2list(messages)
      |> Enum.map(fn {msg} -> Jason.decode!(msg) end)
    end

    test "subscribe sends ack", %{state: state, messages: messages} do
      msg = Jason.encode!(%{
        "type" => "subscribe",
        "conversation_id" => "conv_1",
        "request_id" => "req_1"
      })

      {:ok, new_state} = Handler.handle_message(msg, state)
      assert Map.has_key?(new_state.subscriptions, "conv_1")

      acks = sent_messages(messages)
      assert length(acks) == 1
      assert hd(acks)["type"] == "ack"
      assert hd(acks)["request_id"] == "req_1"
      assert hd(acks)["status"] == "ok"
    end

    test "unsubscribe removes subscription", %{state: state, messages: messages} do
      # First subscribe
      sub_msg = Jason.encode!(%{"type" => "subscribe", "conversation_id" => "conv_1"})
      {:ok, state} = Handler.handle_message(sub_msg, state)

      # Then unsubscribe
      unsub_msg = Jason.encode!(%{"type" => "unsubscribe", "conversation_id" => "conv_1"})
      {:ok, state} = Handler.handle_message(unsub_msg, state)

      refute Map.has_key?(state.subscriptions, "conv_1")
    end

    test "post_message with idempotency key", %{state: state, messages: messages} do
      msg = Jason.encode!(%{
        "type" => "post_message",
        "conversation_id" => "conv_1",
        "content" => "hello",
        "request_id" => "req_2",
        "idempotency_key" => "idem_1"
      })

      {:ok, state} = Handler.handle_message(msg, state)

      acks = sent_messages(messages)
      first_ack = Enum.find(acks, &(&1["request_id"] == "req_2"))
      assert first_ack["status"] == "ok"
      assert first_ack["data"]["message_id"]

      # Retry with same idempotency key
      :ets.delete_all_objects(messages)
      {:ok, _state} = Handler.handle_message(msg, state)

      retry_acks = sent_messages(messages)
      retry_ack = Enum.find(retry_acks, &(&1["request_id"] == "req_2"))
      assert retry_ack["data"]["message_id"] == first_ack["data"]["message_id"]
    end

    test "invalid JSON returns error", %{state: state, messages: messages} do
      {:error, _, _state} = Handler.handle_message("not json {{{", state)
      errors = sent_messages(messages)
      assert hd(errors)["status"] == "error"
    end

    test "missing conversation_id returns error", %{state: state, messages: messages} do
      msg = Jason.encode!(%{"type" => "subscribe", "request_id" => "req_err"})
      {:error, _, _state} = Handler.handle_message(msg, state)

      errors = sent_messages(messages)
      assert Enum.any?(errors, &(&1["status"] == "error"))
    end

    test "deliver_event sends event to subscribed client", %{state: state} do
      # Subscribe first
      sub_msg = Jason.encode!(%{"type" => "subscribe", "conversation_id" => "conv_1"})
      {:ok, state} = Handler.handle_message(sub_msg, state)

      rune = Schema.new(
        conversation_id: "conv_1",
        kind: "turn.started",
        payload: %{"input" => "test"},
        event_id: 42
      )

      state = Handler.deliver_event(state, "conv_1", rune)

      # Cursor should be updated
      assert state.subscriptions["conv_1"].cursor == 42
    end

    test "approve sends ack", %{state: state, messages: messages} do
      msg = Jason.encode!(%{
        "type" => "approve",
        "call_id" => "call_1",
        "decision" => "approved",
        "request_id" => "req_approve"
      })

      {:ok, _state} = Handler.handle_message(msg, state)

      acks = sent_messages(messages)
      ack = Enum.find(acks, &(&1["request_id"] == "req_approve"))
      assert ack["status"] == "ok"
    end
  end
end
