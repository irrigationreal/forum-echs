defmodule EchsCore.Observability.DebugBundleTest do
  use ExUnit.Case, async: true

  alias EchsCore.Observability.DebugBundle
  alias EchsCore.Rune.{Schema, RunelogWriter, Snapshot}

  @moduletag :tmp_dir

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp make_rune(kind, payload, opts \\ []) do
    Schema.new(
      Keyword.merge(
        [conversation_id: "conv_dbg", kind: kind, payload: payload],
        opts
      )
    )
  end

  defp start_writer(dir) do
    {:ok, writer} = RunelogWriter.start_link(dir: dir, conversation_id: "conv_dbg", fsync: :none)
    writer
  end

  defp populate_runelog(dir) do
    writer = start_writer(dir)

    # Turn 1: started, tool call, tool result, usage, completed
    RunelogWriter.append(writer, make_rune("turn.started", %{
      "input" => "hello world",
      "model" => "gpt-5.3-codex"
    }, turn_id: "t1"))

    RunelogWriter.append(writer, make_rune("tool.call", %{
      "call_id" => "call_001",
      "name" => "shell",
      "arguments" => ~s({"cmd": "ls -la"})
    }, turn_id: "t1"))

    RunelogWriter.append(writer, make_rune("tool.result", %{
      "call_id" => "call_001",
      "status" => "success",
      "output" => "total 42\ndrwxr-xr-x  5 user user 4096 Jan  1 00:00 .\n"
    }, turn_id: "t1"))

    RunelogWriter.append(writer, make_rune("turn.usage", %{
      "input_tokens" => 150,
      "output_tokens" => 75
    }, turn_id: "t1"))

    RunelogWriter.append(writer, make_rune("turn.completed", %{}, turn_id: "t1"))

    # Turn 2: with error
    RunelogWriter.append(writer, make_rune("turn.started", %{
      "input" => "run tests",
      "model" => "gpt-5.3-codex"
    }, turn_id: "t2"))

    RunelogWriter.append(writer, make_rune("turn.error", %{
      "error_type" => "timeout",
      "message" => "provider timed out"
    }, turn_id: "t2"))

    RunelogWriter.flush(writer)
    GenServer.stop(writer)
  end

  defp populate_with_snapshot(tmp_dir) do
    seg_dir = Path.join(tmp_dir, "segments")
    snap_dir = Path.join(tmp_dir, "snapshots")
    File.mkdir_p!(seg_dir)
    File.mkdir_p!(snap_dir)

    populate_runelog(seg_dir)

    state = %{
      "conversation_id" => "conv_dbg",
      "agent_states" => %{"agt_root" => %{"status" => "idle"}},
      "config" => %{"model" => "gpt-5.3-codex"},
      "tools" => [%{"name" => "shell"}],
      "metadata" => %{"created_at" => 1_700_000_000}
    }

    Snapshot.write(snap_dir, 5, state)
    {seg_dir, snap_dir}
  end

  # -------------------------------------------------------------------
  # generate/2
  # -------------------------------------------------------------------

  describe "generate/2" do
    @tag :tmp_dir
    test "generates a bundle with runes from runelog", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir)

      assert bundle[:version] == 1
      assert bundle[:conversation_id] == "conv_dbg"
      assert is_integer(bundle[:generated_at])
      assert length(bundle[:runes]) == 7
      assert bundle[:snapshot] == nil

      # Check runes are properly encoded maps (not structs)
      first = hd(bundle[:runes])
      assert is_map(first)
      assert first["kind"] == "turn.started"
      assert first["conversation_id"] == "conv_dbg"
    end

    @tag :tmp_dir
    test "includes snapshot when snapshot_dir is provided", %{tmp_dir: tmp_dir} do
      {seg_dir, snap_dir} = populate_with_snapshot(tmp_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        snapshot_dir: snap_dir
      )

      assert bundle[:snapshot] != nil
      assert bundle[:snapshot]["event_id"] == 5
      assert bundle[:snapshot]["state"]["conversation_id"] == "conv_dbg"
    end

    @tag :tmp_dir
    test "extracts provider metadata", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir)

      meta = bundle[:provider_metadata]
      assert meta["model"] == "gpt-5.3-codex"
      assert meta["total_input_tokens"] == 150
      assert meta["total_output_tokens"] == 75
      assert meta["turn_count"] == 2
    end

    @tag :tmp_dir
    test "collects system info", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir)

      sys = bundle[:system_info]
      assert is_binary(sys["elixir_version"])
      assert is_binary(sys["otp_version"])
      assert is_binary(sys["os"])
      assert sys["bundle_schema_version"] == 1
    end

    @tag :tmp_dir
    test "computes stats correctly", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir)

      stats = bundle[:stats]
      assert stats["original_rune_count"] == 7
      assert stats["included_rune_count"] == 7
      assert stats["tool_call_count"] == 1
      assert stats["error_count"] == 1
      assert is_integer(stats["first_ts_ms"])
      assert is_integer(stats["last_ts_ms"])
      assert stats["last_ts_ms"] >= stats["first_ts_ms"]
    end

    @tag :tmp_dir
    test "respects max_runes limit", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        max_runes: 3
      )

      assert length(bundle[:runes]) == 3
      # Should be the first 3 runes
      eids = Enum.map(bundle[:runes], &Map.get(&1, "event_id"))
      assert eids == [1, 2, 3]
    end

    @tag :tmp_dir
    test "returns empty bundle for nonexistent conversation", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_nonexistent", segment_dir: seg_dir)

      assert bundle[:runes] == []
      assert bundle[:conversation_id] == "conv_nonexistent"
    end

    @tag :tmp_dir
    test "skips snapshot when include_snapshot is false", %{tmp_dir: tmp_dir} do
      {seg_dir, snap_dir} = populate_with_snapshot(tmp_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        snapshot_dir: snap_dir,
        include_snapshot: false
      )

      assert bundle[:snapshot] == nil
    end
  end

  # -------------------------------------------------------------------
  # Tool output sanitization
  # -------------------------------------------------------------------

  describe "tool output sanitization" do
    @tag :tmp_dir
    test "truncates large tool outputs", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      writer = start_writer(seg_dir)

      large_output = String.duplicate("x", 20_000)

      RunelogWriter.append(writer, make_rune("tool.result", %{
        "call_id" => "call_big",
        "status" => "success",
        "output" => large_output
      }))

      RunelogWriter.flush(writer)
      GenServer.stop(writer)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        max_tool_output_bytes: 1_000,
        redact: false
      )

      tool_rune = hd(bundle[:runes])
      output = tool_rune["payload"]["output"]
      assert byte_size(output) < 20_000
      assert String.contains?(output, "[truncated")
      assert tool_rune["payload"]["_truncated"] == true
      assert tool_rune["payload"]["_original_bytes"] == 20_000
    end

    @tag :tmp_dir
    test "truncates large tool call arguments", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      writer = start_writer(seg_dir)

      large_args = String.duplicate("a", 20_000)

      RunelogWriter.append(writer, make_rune("tool.call", %{
        "call_id" => "call_bigarg",
        "name" => "shell",
        "arguments" => large_args
      }))

      RunelogWriter.flush(writer)
      GenServer.stop(writer)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        max_tool_output_bytes: 500,
        redact: false
      )

      tool_rune = hd(bundle[:runes])
      assert tool_rune["payload"]["_truncated"] == true
      assert String.contains?(tool_rune["payload"]["arguments"], "[truncated")
    end
  end

  # -------------------------------------------------------------------
  # redact_secrets/1
  # -------------------------------------------------------------------

  describe "redact_secrets/1" do
    test "redacts known sensitive keys" do
      input = %{
        "api_key" => "sk-abc123456789012345678",
        "data" => "safe value",
        "password" => "super_secret_pass"
      }

      result = DebugBundle.redact_secrets(input)

      assert result["api_key"] == "[REDACTED]"
      assert result["data"] == "safe value"
      assert result["password"] == "[REDACTED]"
    end

    test "redacts nested sensitive keys" do
      input = %{
        "config" => %{
          "api_key" => "sk-nested-key-value",
          "model" => "gpt-5.3-codex"
        },
        "name" => "test"
      }

      result = DebugBundle.redact_secrets(input)

      assert result["config"]["api_key"] == "[REDACTED]"
      assert result["config"]["model"] == "gpt-5.3-codex"
      assert result["name"] == "test"
    end

    test "redacts sensitive keys in lists" do
      input = [
        %{"token" => "bearer-abc123", "kind" => "auth"},
        %{"data" => "safe"}
      ]

      result = DebugBundle.redact_secrets(input)

      assert hd(result)["token"] == "[REDACTED]"
      assert hd(result)["kind"] == "auth"
    end

    test "redacts API key patterns in strings" do
      input = "Authorization: Bearer sk-proj-abcdefghijklmnopqrst"
      result = DebugBundle.redact_secrets(input)
      refute String.contains?(result, "sk-proj-abcdefghijklmnopqrst")
      assert String.contains?(result, "[REDACTED]")
    end

    test "redacts AWS-style access keys" do
      input = "aws_key = AKIAIOSFODNN7EXAMPLE"
      result = DebugBundle.redact_secrets(input)
      refute String.contains?(result, "AKIAIOSFODNN7EXAMPLE")
    end

    test "redacts JWT tokens" do
      jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
      result = DebugBundle.redact_secrets(jwt)
      refute String.contains?(result, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
    end

    test "leaves safe values untouched" do
      input = %{
        "message" => "Hello, world!",
        "count" => 42,
        "active" => true,
        "items" => ["a", "b", "c"]
      }

      result = DebugBundle.redact_secrets(input)
      assert result == input
    end

    test "handles nil and other non-map types" do
      assert DebugBundle.redact_secrets(nil) == nil
      assert DebugBundle.redact_secrets(42) == 42
      assert DebugBundle.redact_secrets(true) == true
    end

    test "is case-insensitive for sensitive keys" do
      input = %{
        "API_KEY" => "my-key",
        "Password" => "my-pass",
        "ACCESS_TOKEN" => "my-token"
      }

      result = DebugBundle.redact_secrets(input)
      assert result["API_KEY"] == "[REDACTED]"
      assert result["Password"] == "[REDACTED]"
      assert result["ACCESS_TOKEN"] == "[REDACTED]"
    end
  end

  # -------------------------------------------------------------------
  # Secret redaction in generate/2
  # -------------------------------------------------------------------

  describe "secret redaction in bundles" do
    @tag :tmp_dir
    test "redacts secrets from rune payloads during generation", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      writer = start_writer(seg_dir)

      RunelogWriter.append(writer, make_rune("session.config", %{
        "api_key" => "sk-abcdef0123456789abcdef",
        "model" => "gpt-5.3-codex"
      }))

      RunelogWriter.flush(writer)
      GenServer.stop(writer)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir, redact: true)

      config_rune = hd(bundle[:runes])
      assert config_rune["payload"]["api_key"] == "[REDACTED]"
      assert config_rune["payload"]["model"] == "gpt-5.3-codex"
    end

    @tag :tmp_dir
    test "does not redact when redact: false", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      writer = start_writer(seg_dir)

      RunelogWriter.append(writer, make_rune("session.config", %{
        "api_key" => "sk-abcdef0123456789abcdef",
        "model" => "gpt-5.3-codex"
      }))

      RunelogWriter.flush(writer)
      GenServer.stop(writer)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir, redact: false)

      config_rune = hd(bundle[:runes])
      assert config_rune["payload"]["api_key"] == "sk-abcdef0123456789abcdef"
    end
  end

  # -------------------------------------------------------------------
  # Size limiting
  # -------------------------------------------------------------------

  describe "size limiting" do
    @tag :tmp_dir
    test "trims runes to stay under max_bytes", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      writer = start_writer(seg_dir)

      # Write many runes to exceed a small limit
      for i <- 1..100 do
        RunelogWriter.append(writer, make_rune(
          "turn.assistant_delta",
          %{"content" => String.duplicate("data-#{i}-", 50)},
          turn_id: "t#{i}"
        ))
      end

      RunelogWriter.flush(writer)
      GenServer.stop(writer)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        max_bytes: 5_000,
        redact: false
      )

      json = Jason.encode!(bundle)
      assert byte_size(json) <= 5_000
      assert length(bundle[:runes]) < 100
    end

    @tag :tmp_dir
    test "does not trim when under limit", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        max_bytes: 10_000_000,
        redact: false
      )

      assert length(bundle[:runes]) == 7
      stats = bundle[:stats]
      assert stats["trimmed"] == nil or stats["trimmed"] == false
    end
  end

  # -------------------------------------------------------------------
  # summarize/1
  # -------------------------------------------------------------------

  describe "summarize/1" do
    @tag :tmp_dir
    test "produces a readable text summary", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg", segment_dir: seg_dir)

      summary = DebugBundle.summarize(bundle)

      assert is_binary(summary)
      assert String.contains?(summary, "conv_dbg")
      assert String.contains?(summary, "gpt-5.3-codex")
      assert String.contains?(summary, "7 total")
      assert String.contains?(summary, "Tool calls: 1")
      assert String.contains?(summary, "Errors: 1")
      assert String.contains?(summary, "Turn count: 2")
    end

    test "handles empty bundle gracefully" do
      bundle = %{
        version: 1,
        conversation_id: "conv_empty",
        generated_at: 1_700_000_000_000,
        system_info: %{},
        runes: [],
        snapshot: nil,
        provider_metadata: %{},
        stats: %{}
      }

      summary = DebugBundle.summarize(bundle)

      assert is_binary(summary)
      assert String.contains?(summary, "conv_empty")
      assert String.contains?(summary, "0 total")
    end
  end

  # -------------------------------------------------------------------
  # write_json/2 and from_json/1
  # -------------------------------------------------------------------

  describe "JSON round-trip" do
    @tag :tmp_dir
    test "write_json and from_json round-trip", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        redact: false
      )

      json_path = Path.join(tmp_dir, "debug_bundle.json")
      {:ok, ^json_path} = DebugBundle.write_json(bundle, json_path)

      assert File.exists?(json_path)

      {:ok, loaded} = DebugBundle.from_json(json_path)

      assert loaded["conversation_id"] == "conv_dbg"
      assert loaded["version"] == 1
      assert length(loaded["runes"]) == 7
    end
  end

  # -------------------------------------------------------------------
  # write_tarball/2 and from_tarball/1
  # -------------------------------------------------------------------

  describe "tarball round-trip" do
    @tag :tmp_dir
    test "write_tarball and from_tarball round-trip", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        redact: false
      )

      tar_path = Path.join(tmp_dir, "debug_bundle.tar.gz")
      {:ok, ^tar_path} = DebugBundle.write_tarball(bundle, tar_path)

      assert File.exists?(tar_path)

      {:ok, loaded} = DebugBundle.from_tarball(tar_path)

      assert loaded["conversation_id"] == "conv_dbg"
      assert loaded["version"] == 1
      assert length(loaded["runes"]) == 7
    end

    @tag :tmp_dir
    test "tarball contains both bundle.json and summary.txt", %{tmp_dir: tmp_dir} do
      seg_dir = Path.join(tmp_dir, "segments")
      File.mkdir_p!(seg_dir)
      populate_runelog(seg_dir)

      {:ok, bundle} = DebugBundle.generate("conv_dbg",
        segment_dir: seg_dir,
        redact: false
      )

      tar_path = Path.join(tmp_dir, "debug_bundle.tar.gz")
      {:ok, _} = DebugBundle.write_tarball(bundle, tar_path)

      {:ok, files} = :erl_tar.extract(tar_path, [:compressed, :memory])
      names = Enum.map(files, fn {name, _data} -> List.to_string(name) end)

      assert "bundle.json" in names
      assert "summary.txt" in names
    end
  end
end
