defmodule EchsCore.Rune.SnapshotTest do
  use ExUnit.Case, async: true

  alias EchsCore.Rune.Snapshot

  @moduletag :tmp_dir

  defp sample_state(conversation_id \\ "conv_snap") do
    %{
      "conversation_id" => conversation_id,
      "agent_states" => %{"agt_root" => %{"status" => "idle"}},
      "config" => %{"model" => "gpt-5.3-codex"},
      "tools" => [%{"name" => "shell"}],
      "metadata" => %{"created_at" => 1_700_000_000}
    }
  end

  describe "write/4 and read/1" do
    @tag :tmp_dir
    test "round-trips a snapshot", %{tmp_dir: tmp_dir} do
      state = sample_state()
      {:ok, path} = Snapshot.write(tmp_dir, 100, state)

      assert File.exists?(path)
      assert String.ends_with?(path, ".snap")

      {:ok, event_id, read_state} = Snapshot.read(path)
      assert event_id == 100
      assert read_state == state
    end

    @tag :tmp_dir
    test "detects corruption (integrity check)", %{tmp_dir: tmp_dir} do
      state = sample_state()
      {:ok, path} = Snapshot.write(tmp_dir, 50, state)

      # Corrupt a byte in the payload portion (after the 44-byte header)
      {:ok, data} = File.read(path)
      corrupt_pos = 50  # Well into the JSON payload
      corrupted = binary_part(data, 0, corrupt_pos) <> <<0xFF>> <> binary_part(data, corrupt_pos + 1, byte_size(data) - corrupt_pos - 1)
      File.write!(path, corrupted)

      assert {:error, :integrity_check_failed} = Snapshot.read(path)
    end

    @tag :tmp_dir
    test "detects truncated file", %{tmp_dir: tmp_dir} do
      state = sample_state()
      {:ok, path} = Snapshot.write(tmp_dir, 50, state)

      # Truncate the file
      File.write!(path, <<0, 0, 0>>)

      assert {:error, :truncated} = Snapshot.read(path)
    end
  end

  describe "list/2" do
    @tag :tmp_dir
    test "lists snapshots sorted by event_id", %{tmp_dir: tmp_dir} do
      state = sample_state()
      Snapshot.write(tmp_dir, 100, state)
      Snapshot.write(tmp_dir, 200, state)
      Snapshot.write(tmp_dir, 50, state)

      snapshots = Snapshot.list(tmp_dir, "conv_snap")
      eids = Enum.map(snapshots, &elem(&1, 0))
      assert eids == [50, 100, 200]
    end

    @tag :tmp_dir
    test "returns empty list for no snapshots", %{tmp_dir: tmp_dir} do
      assert Snapshot.list(tmp_dir, "conv_none") == []
    end
  end

  describe "latest/3" do
    @tag :tmp_dir
    test "finds the latest snapshot", %{tmp_dir: tmp_dir} do
      state = sample_state()
      Snapshot.write(tmp_dir, 50, state)
      Snapshot.write(tmp_dir, 100, state)
      Snapshot.write(tmp_dir, 200, state)

      {:ok, eid, _path} = Snapshot.latest(tmp_dir, "conv_snap")
      assert eid == 200
    end

    @tag :tmp_dir
    test "finds latest before a given event_id", %{tmp_dir: tmp_dir} do
      state = sample_state()
      Snapshot.write(tmp_dir, 50, state)
      Snapshot.write(tmp_dir, 100, state)
      Snapshot.write(tmp_dir, 200, state)

      {:ok, eid, _path} = Snapshot.latest(tmp_dir, "conv_snap", 150)
      assert eid == 100
    end

    @tag :tmp_dir
    test "returns :none when no snapshots exist", %{tmp_dir: tmp_dir} do
      assert :none = Snapshot.latest(tmp_dir, "conv_none")
    end
  end
end
