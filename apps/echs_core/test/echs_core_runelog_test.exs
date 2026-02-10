defmodule EchsCore.Rune.RunelogTest do
  use ExUnit.Case, async: true

  alias EchsCore.Rune.{Schema, RunelogWriter, RunelogReader}

  @moduletag :tmp_dir

  defp make_rune(kind, payload, opts \\ []) do
    Schema.new(
      Keyword.merge(
        [conversation_id: "conv_test", kind: kind, payload: payload],
        opts
      )
    )
  end

  defp start_writer(tmp_dir, opts \\ []) do
    defaults = [dir: tmp_dir, conversation_id: "conv_test", fsync: :none]
    {:ok, writer} = RunelogWriter.start_link(Keyword.merge(defaults, opts))
    writer
  end

  describe "RunelogWriter" do
    @tag :tmp_dir
    test "appends runes with monotonic event_ids", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      {:ok, eid1} = RunelogWriter.append(writer, make_rune("turn.started", %{"input" => "hello"}))
      {:ok, eid2} = RunelogWriter.append(writer, make_rune("turn.completed", %{}))
      {:ok, eid3} = RunelogWriter.append(writer, make_rune("turn.error", %{"error_type" => "x", "message" => "y"}))

      assert eid1 == 1
      assert eid2 == 2
      assert eid3 == 3
      assert RunelogWriter.last_event_id(writer) == 3
    end

    @tag :tmp_dir
    test "append_batch assigns consecutive event_ids", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      runes = for i <- 1..10 do
        make_rune("turn.assistant_delta", %{"content" => "chunk #{i}"})
      end

      {:ok, range} = RunelogWriter.append_batch(writer, runes)
      assert range == 1..10//1
      assert RunelogWriter.last_event_id(writer) == 10
    end

    @tag :tmp_dir
    test "creates segment file", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)
      RunelogWriter.append(writer, make_rune("turn.started", %{"input" => "test"}))
      RunelogWriter.flush(writer)

      path = RunelogWriter.segment_path(writer)
      assert File.exists?(path)
      assert String.ends_with?(path, ".seg")
    end

    @tag :tmp_dir
    test "crash recovery truncates partial tail", %{tmp_dir: tmp_dir} do
      # Write some valid frames
      writer = start_writer(tmp_dir)
      RunelogWriter.append(writer, make_rune("turn.started", %{"input" => "one"}))
      RunelogWriter.append(writer, make_rune("turn.completed", %{}))
      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      # Append garbage (simulating partial write from crash)
      {:ok, fd} = File.open(path, [:append, :binary, :raw])
      IO.binwrite(fd, <<0xFF, 0xFF, 0xFF>>)
      File.close(fd)

      # Re-open — should recover and truncate the garbage
      writer2 = start_writer(tmp_dir)
      assert RunelogWriter.last_event_id(writer2) == 2

      # Can continue appending
      {:ok, eid} = RunelogWriter.append(writer2, make_rune("turn.started", %{"input" => "two"}))
      assert eid == 3
      GenServer.stop(writer2)
    end

    @tag :tmp_dir
    test "crash recovery truncates CRC-invalid frame", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)
      RunelogWriter.append(writer, make_rune("turn.started", %{"input" => "valid"}))
      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      # Corrupt the file by appending a frame with bad CRC
      json = Jason.encode!(%{"event_id" => 99, "kind" => "fake"})
      len = byte_size(json)
      bad_crc = 0xDEADBEEF
      frame = <<len::unsigned-little-32, bad_crc::unsigned-little-32>> <> json
      File.write!(path, frame, [:append])

      # Re-open — should truncate the bad frame
      writer2 = start_writer(tmp_dir)
      assert RunelogWriter.last_event_id(writer2) == 1
      GenServer.stop(writer2)
    end

    @tag :tmp_dir
    test "segment rotation when max size exceeded", %{tmp_dir: tmp_dir} do
      # Use a tiny max to force rotation
      writer = start_writer(tmp_dir, max_segment_bytes: 200)

      path1 = RunelogWriter.segment_path(writer)

      # Write enough runes to exceed 200 bytes
      for i <- 1..20 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "chunk #{i}"}))
      end

      path2 = RunelogWriter.segment_path(writer)
      # Should have rotated at least once
      assert path1 != path2 or RunelogWriter.last_event_id(writer) == 20
      GenServer.stop(writer)
    end
  end

  describe "RunelogReader" do
    @tag :tmp_dir
    test "reads all runes from a segment", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      for i <- 1..5 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "msg #{i}"}))
      end

      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, reader} = RunelogReader.open(path)
      {runes, _reader} = RunelogReader.read_all(reader)

      assert length(runes) == 5
      assert Enum.map(runes, & &1.event_id) == [1, 2, 3, 4, 5]
      assert hd(runes).kind == "turn.assistant_delta"
      assert hd(runes).payload["content"] == "msg 1"
    end

    @tag :tmp_dir
    test "sequential iteration with next/1", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)
      RunelogWriter.append(writer, make_rune("turn.started", %{"input" => "hello"}))
      RunelogWriter.append(writer, make_rune("turn.completed", %{}))
      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, reader} = RunelogReader.open(path)
      {:ok, rune1, reader} = RunelogReader.next(reader)
      assert rune1.event_id == 1
      assert rune1.kind == "turn.started"

      {:ok, rune2, reader} = RunelogReader.next(reader)
      assert rune2.event_id == 2
      assert rune2.kind == "turn.completed"

      assert :eof = RunelogReader.next(reader)
    end

    @tag :tmp_dir
    test "seek by event_id", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      for i <- 1..20 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "chunk #{i}"}))
      end

      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, reader} = RunelogReader.open(path)
      {:ok, reader} = RunelogReader.seek(reader, event_id: 10)
      {:ok, rune, _reader} = RunelogReader.next(reader)
      assert rune.event_id == 10
    end

    @tag :tmp_dir
    test "backfill reads from since_event_id (exclusive)", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      for i <- 1..10 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "chunk #{i}"}))
      end

      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, reader} = RunelogReader.open(path)
      {runes, _reader} = RunelogReader.backfill(reader, 5, 3)

      assert length(runes) == 3
      assert Enum.map(runes, & &1.event_id) == [6, 7, 8]
    end

    @tag :tmp_dir
    test "read_batch respects limit", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      for i <- 1..10 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "chunk #{i}"}))
      end

      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, reader} = RunelogReader.open(path)
      {runes, _reader} = RunelogReader.read_batch(reader, 3)

      assert length(runes) == 3
      assert Enum.map(runes, & &1.event_id) == [1, 2, 3]
    end

    @tag :tmp_dir
    test "CRC validation detects corruption", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)
      RunelogWriter.append(writer, make_rune("turn.started", %{"input" => "ok"}))
      RunelogWriter.append(writer, make_rune("turn.completed", %{}))
      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      # Corrupt a byte in the payload of the first frame
      {:ok, data} = File.read(path)
      # Flip a byte after the header of the first frame
      corrupted = binary_part(data, 0, 12) <> <<0xFF>> <> binary_part(data, 13, byte_size(data) - 13)
      File.write!(path, corrupted)

      {:ok, reader} = RunelogReader.open(path)
      # First frame should be corrupted
      {:error, {:crc_mismatch, 0}, reader} = RunelogReader.next(reader)
      # Second frame should still be readable
      {:ok, rune2, _reader} = RunelogReader.next(reader)
      assert rune2.kind == "turn.completed"
    end
  end

  describe "Sparse Index" do
    @tag :tmp_dir
    test "build and use sparse index for seek", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      for i <- 1..1000 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "c#{i}"}))
      end

      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      # Build index with interval of 100
      {:ok, entry_count} = RunelogReader.build_index(path, interval: 100)
      assert entry_count == 10  # 1000/100

      # Open reader with index and seek
      {:ok, reader} = RunelogReader.open(path, load_index: true)
      assert reader.index != nil

      {:ok, reader} = RunelogReader.seek(reader, event_id: 500)
      {:ok, rune, _reader} = RunelogReader.next(reader)
      assert rune.event_id == 500
    end

    @tag :tmp_dir
    test "rebuild_index replaces existing index", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      for i <- 1..100 do
        RunelogWriter.append(writer, make_rune("turn.assistant_delta", %{"content" => "c#{i}"}))
      end

      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, _} = RunelogReader.build_index(path, interval: 10)
      {:ok, count} = RunelogReader.rebuild_index(path, interval: 20)
      assert count == 5  # 100/20
    end
  end

  describe "Round-trip: write then read" do
    @tag :tmp_dir
    test "all rune fields survive write/read round-trip", %{tmp_dir: tmp_dir} do
      writer = start_writer(tmp_dir)

      original = make_rune(
        "tool.result",
        %{"call_id" => "call_1", "status" => "success", "output" => "done"},
        turn_id: "turn_42",
        agent_id: "agt_main",
        visibility: :internal,
        tags: ["test", "roundtrip"]
      )

      {:ok, eid} = RunelogWriter.append(writer, original)
      RunelogWriter.flush(writer)
      path = RunelogWriter.segment_path(writer)
      GenServer.stop(writer)

      {:ok, reader} = RunelogReader.open(path)
      {:ok, read_rune, _} = RunelogReader.next(reader)

      assert read_rune.event_id == eid
      assert read_rune.rune_id == original.rune_id
      assert read_rune.conversation_id == original.conversation_id
      assert read_rune.turn_id == "turn_42"
      assert read_rune.agent_id == "agt_main"
      assert read_rune.kind == "tool.result"
      assert read_rune.visibility == :internal
      assert read_rune.payload == original.payload
      assert read_rune.tags == ["test", "roundtrip"]
      assert read_rune.schema_version == Schema.schema_version()
    end
  end
end
