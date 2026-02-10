defmodule EchsCore.Rune.Compaction do
  @moduledoc """
  Idempotent, crash-safe compaction of Runelog segments.

  Compaction removes segments that are fully covered by a snapshot,
  reducing disk usage while preserving the ability to replay from
  the snapshot point forward.

  ## Process

  1. Find the latest valid snapshot for the conversation
  2. Identify segments whose entire range is <= the snapshot event_id
  3. Move those segments to a trash directory (recoverable)
  4. Optionally purge the trash after a retention period

  ## Crash Safety

  Compaction is idempotent: running it multiple times produces the same
  result. If the process crashes mid-compaction, partial moves are safe
  because segments are moved (not deleted) and the snapshot still exists.
  """

  require Logger

  alias EchsCore.Rune.{Snapshot, RunelogReader}

  @doc """
  Compact old segments for a conversation.

  Moves segments that are fully covered by the latest snapshot to a
  trash directory. Returns the number of segments compacted.

  Options:
    * `:snapshot_dir` — directory containing snapshots (required)
    * `:segment_dir` — directory containing segments (required)
    * `:trash_dir` — directory for compacted segments (default: segment_dir/trash)
  """
  @spec compact(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def compact(conversation_id, opts) do
    snapshot_dir = Keyword.fetch!(opts, :snapshot_dir)
    segment_dir = Keyword.fetch!(opts, :segment_dir)
    trash_dir = Keyword.get(opts, :trash_dir, Path.join(segment_dir, "trash"))

    case Snapshot.latest(snapshot_dir, conversation_id) do
      :none ->
        {:ok, 0}

      {:ok, snap_event_id, snap_path} ->
        # Verify snapshot integrity before compacting
        case Snapshot.read(snap_path) do
          {:ok, ^snap_event_id, _state} ->
            do_compact(conversation_id, segment_dir, trash_dir, snap_event_id)

          {:error, reason} ->
            Logger.error("Compaction aborted: snapshot integrity check failed: #{inspect(reason)}")
            {:error, {:snapshot_integrity, reason}}
        end
    end
  end

  @doc """
  Purge trashed segments older than the given age (in milliseconds).
  """
  @spec purge_trash(String.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def purge_trash(trash_dir, max_age_ms) do
    cutoff = System.system_time(:millisecond) - max_age_ms

    case File.ls(trash_dir) do
      {:ok, files} ->
        count =
          files
          |> Enum.filter(&String.ends_with?(&1, ".seg"))
          |> Enum.count(fn filename ->
            path = Path.join(trash_dir, filename)

            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime}} when mtime * 1000 < cutoff ->
                File.rm!(path)
                # Also remove index if present
                File.rm(String.replace_trailing(path, ".seg", ".idx"))
                true

              _ ->
                false
            end
          end)

        {:ok, count}

      {:error, :enoent} ->
        {:ok, 0}
    end
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp do_compact(conversation_id, segment_dir, trash_dir, snap_event_id) do
    segments = list_segments(segment_dir, conversation_id)

    # Find segments whose entire range is <= snap_event_id
    compactable =
      Enum.filter(segments, fn {_path, _start_eid, end_eid} ->
        end_eid <= snap_event_id
      end)

    if compactable == [] do
      {:ok, 0}
    else
      File.mkdir_p!(trash_dir)

      count =
        Enum.count(compactable, fn {path, _start, _end} ->
          filename = Path.basename(path)
          dest = Path.join(trash_dir, filename)

          case File.rename(path, dest) do
            :ok ->
              # Also move the index file if it exists
              idx_path = String.replace_trailing(path, ".seg", ".idx")
              idx_dest = String.replace_trailing(dest, ".seg", ".idx")
              File.rename(idx_path, idx_dest)
              true

            {:error, reason} ->
              Logger.warning("Failed to compact segment #{path}: #{inspect(reason)}")
              false
          end
        end)

      Logger.info("Compacted #{count} segments for #{conversation_id} (snap at #{snap_event_id})")
      {:ok, count}
    end
  end

  defp list_segments(dir, conversation_id) do
    prefix = "#{conversation_id}_"

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".seg")))
        |> Enum.sort()
        |> Enum.map(fn filename ->
          path = Path.join(dir, filename)

          start_str =
            filename
            |> String.trim_leading(prefix)
            |> String.trim_trailing(".seg")

          {start_eid, _} = Integer.parse(start_str)

          # Read the segment to find the last event_id
          end_eid =
            case RunelogReader.open(path, load_index: false) do
              {:ok, reader} ->
                {runes, _} = RunelogReader.read_all(reader)

                case List.last(runes) do
                  nil -> start_eid
                  rune -> rune.event_id
                end

              {:error, _} ->
                start_eid
            end

          {path, start_eid, end_eid}
        end)

      {:error, _} ->
        []
    end
  end
end
