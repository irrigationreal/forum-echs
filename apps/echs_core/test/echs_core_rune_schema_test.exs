defmodule EchsCore.Rune.SchemaTest do
  use ExUnit.Case, async: true

  alias EchsCore.Rune.Schema

  describe "new/1" do
    test "creates a rune with required fields" do
      rune = Schema.new(
        conversation_id: "conv_abc123",
        kind: "turn.started",
        payload: %{"input" => "hello"}
      )

      assert rune.conversation_id == "conv_abc123"
      assert rune.kind == "turn.started"
      assert rune.payload == %{"input" => "hello"}
      assert rune.visibility == :public
      assert rune.tags == []
      assert rune.schema_version == Schema.schema_version()
      assert String.starts_with?(rune.rune_id, "run_")
      assert byte_size(rune.rune_id) == 4 + 16  # "run_" + 16 hex chars
      assert is_integer(rune.ts_ms)
      assert rune.event_id == nil
    end

    test "creates a rune with optional fields" do
      rune = Schema.new(
        conversation_id: "conv_abc123",
        kind: "tool.call",
        payload: %{"call_id" => "call_1", "tool_name" => "shell", "arguments" => %{}},
        turn_id: "turn_1",
        agent_id: "agt_xyz",
        visibility: :internal,
        tags: ["debug"],
        ts_ms: 1_700_000_000_000
      )

      assert rune.turn_id == "turn_1"
      assert rune.agent_id == "agt_xyz"
      assert rune.visibility == :internal
      assert rune.tags == ["debug"]
      assert rune.ts_ms == 1_700_000_000_000
    end

    test "uses kind default visibility when not specified" do
      rune = Schema.new(
        conversation_id: "conv_1",
        kind: "system.invariant_violation",
        payload: %{"invariant_id" => "INV-TEST", "severity" => "error", "message" => "test"}
      )

      assert rune.visibility == :internal
    end
  end

  describe "encode/1 and decode/1 round-trip" do
    test "round-trips a rune through encode/decode" do
      original = Schema.new(
        conversation_id: "conv_roundtrip",
        kind: "turn.completed",
        payload: %{"usage" => %{"input" => 100, "output" => 50}},
        turn_id: "turn_5",
        agent_id: "agt_main",
        visibility: :public,
        tags: ["test", "roundtrip"],
        event_id: 42
      )

      encoded = Schema.encode(original)
      assert is_map(encoded)
      assert encoded["rune_id"] == original.rune_id
      assert encoded["visibility"] == "public"
      assert encoded["event_id"] == 42

      {:ok, decoded} = Schema.decode(encoded)
      assert decoded.rune_id == original.rune_id
      assert decoded.conversation_id == original.conversation_id
      assert decoded.kind == original.kind
      assert decoded.visibility == original.visibility
      assert decoded.ts_ms == original.ts_ms
      assert decoded.payload == original.payload
      assert decoded.tags == original.tags
      assert decoded.event_id == 42
      assert decoded.schema_version == Schema.schema_version()
    end

    test "round-trips through JSON" do
      original = Schema.new(
        conversation_id: "conv_json",
        kind: "tool.result",
        payload: %{
          "call_id" => "call_1",
          "status" => "success",
          "output" => "file created"
        },
        visibility: :public
      )

      {:ok, json} = Schema.encode_json(original)
      assert is_binary(json)

      {:ok, decoded} = Schema.decode_json(json)
      assert decoded.rune_id == original.rune_id
      assert decoded.kind == original.kind
      assert decoded.payload == original.payload
    end

    test "round-trips all visibility levels" do
      for vis <- [:public, :internal, :secret] do
        rune = Schema.new(
          conversation_id: "conv_vis",
          kind: "turn.started",
          payload: %{"input" => "test"},
          visibility: vis
        )

        {:ok, decoded} = rune |> Schema.encode() |> Schema.decode()
        assert decoded.visibility == vis
      end
    end
  end

  describe "encode_json!/1 and decode_json!/1" do
    test "encode_json! returns binary" do
      rune = Schema.new(
        conversation_id: "conv_1",
        kind: "turn.started",
        payload: %{"input" => "hello"}
      )

      json = Schema.encode_json!(rune)
      assert is_binary(json)
      assert String.contains?(json, "turn.started")
    end

    test "decode_json! raises on invalid JSON" do
      assert_raise RuntimeError, fn ->
        Schema.decode_json!("not json {{{")
      end
    end
  end

  describe "filter_visibility/2" do
    setup do
      runes = [
        Schema.new(conversation_id: "c", kind: "turn.started", payload: %{}, visibility: :public),
        Schema.new(conversation_id: "c", kind: "system.error", payload: %{"error_type" => "x", "message" => "y"}, visibility: :internal),
        Schema.new(conversation_id: "c", kind: "turn.completed", payload: %{}, visibility: :secret)
      ]
      {:ok, runes: runes}
    end

    test "public filter returns only public runes", %{runes: runes} do
      filtered = Schema.filter_visibility(runes, :public)
      assert length(filtered) == 1
      assert hd(filtered).visibility == :public
    end

    test "internal filter returns public + internal runes", %{runes: runes} do
      filtered = Schema.filter_visibility(runes, :internal)
      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.visibility in [:public, :internal]))
    end

    test "secret filter returns all runes", %{runes: runes} do
      filtered = Schema.filter_visibility(runes, :secret)
      assert length(filtered) == 3
    end
  end

  describe "valid_kind?/1" do
    test "returns true for registered kinds" do
      assert Schema.valid_kind?("turn.started")
      assert Schema.valid_kind?("tool.call")
      assert Schema.valid_kind?("tool.result")
      assert Schema.valid_kind?("agent.spawning")
      assert Schema.valid_kind?("session.created")
    end

    test "returns false for unregistered kinds" do
      refute Schema.valid_kind?("nonexistent.kind")
      refute Schema.valid_kind?("")
    end
  end

  describe "registered_kinds/0" do
    test "returns a MapSet of all kinds" do
      kinds = Schema.registered_kinds()
      assert is_struct(kinds, MapSet)
      assert MapSet.size(kinds) > 30
      assert MapSet.member?(kinds, "turn.started")
      assert MapSet.member?(kinds, "tool.call")
    end
  end

  describe "default_visibility/1" do
    test "returns kind-specific defaults" do
      assert Schema.default_visibility("turn.started") == :public
      assert Schema.default_visibility("system.invariant_violation") == :internal
      assert Schema.default_visibility("agent.message") == :internal
      assert Schema.default_visibility("plan.critique") == :internal
    end

    test "returns :public for unknown kinds" do
      assert Schema.default_visibility("unknown.kind") == :public
    end
  end

  describe "schema versioning" do
    test "current version is 1" do
      assert Schema.schema_version() == 1
    end

    test "decode rejects future schema versions" do
      map = %{
        "schema_version" => 999,
        "rune_id" => "run_abc",
        "kind" => "turn.started"
      }

      assert {:error, {:unsupported_schema_version, 999}} = Schema.decode(map)
    end

    test "decode accepts maps without schema_version (assumes v1)" do
      map = %{
        "rune_id" => "run_abc123def456ab",
        "conversation_id" => "conv_1",
        "kind" => "turn.started",
        "visibility" => "public",
        "ts_ms" => 1_700_000_000_000,
        "payload" => %{"input" => "hi"}
      }

      assert {:ok, rune} = Schema.decode(map)
      assert rune.schema_version == 1
    end
  end
end
