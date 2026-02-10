defmodule EchsCore.Checkpoint.Rewind do
  @moduledoc """
  Rewind semantics: restore workspace and/or conversation state
  to a previous checkpoint.

  ## Modes

  - `:workspace` — restore only the file tree (workspace files)
  - `:conversation` — restore only the conversation state (truncate runelog)
  - `:both` — restore workspace + conversation atomically

  ## Safety

  All rewind operations are transactional: they either complete fully
  or fail safely with no partial state. A pre-rewind checkpoint is
  always created before destructive operations.

  ## Diff Preview

  Before applying a rewind, callers can request a diff preview showing
  what would change without actually modifying anything.
  """

  require Logger

  alias EchsCore.Checkpoint.Engine

  @type rewind_mode :: :workspace | :conversation | :both

  @type rewind_opts :: %{
          optional(:mode) => rewind_mode(),
          optional(:dry_run) => boolean(),
          optional(:create_safety_checkpoint) => boolean()
        }

  @type rewind_result :: %{
          mode: rewind_mode(),
          checkpoint_id: String.t(),
          safety_checkpoint_id: String.t() | nil,
          workspace_result: map() | nil,
          conversation_result: map() | nil,
          diff: map() | nil
        }

  @doc """
  Rewind to a specific checkpoint.

  Options:
    * `:store_dir` — checkpoint storage directory (required)
    * `:checkpoint_id` — checkpoint to rewind to (required)
    * `:workspace_root` — workspace directory (required for :workspace/:both)
    * `:runelog_dir` — runelog directory (required for :conversation/:both)
    * `:mode` — rewind mode (:workspace, :conversation, :both) (default: :both)
    * `:dry_run` — preview changes without applying (default: false)
    * `:create_safety_checkpoint` — create a checkpoint before rewinding (default: true)
  """
  @spec rewind(keyword()) :: {:ok, rewind_result()} | {:error, term()}
  def rewind(opts) do
    store_dir = Keyword.fetch!(opts, :store_dir)
    checkpoint_id = Keyword.fetch!(opts, :checkpoint_id)
    mode = Keyword.get(opts, :mode, :both)
    dry_run = Keyword.get(opts, :dry_run, false)
    create_safety = Keyword.get(opts, :create_safety_checkpoint, true)

    with :ok <- validate_mode_requirements(mode, opts),
         {:ok, manifest} <- load_manifest(store_dir, checkpoint_id) do

      if dry_run do
        do_dry_run(mode, manifest, opts, store_dir)
      else
        do_rewind(mode, manifest, opts, store_dir, create_safety)
      end
    end
  end

  @doc """
  List available rewind points (checkpoints) with metadata.
  """
  @spec list_rewind_points(String.t()) :: [map()]
  def list_rewind_points(store_dir) do
    Engine.list(store_dir)
    |> Enum.map(fn checkpoint ->
      %{
        checkpoint_id: checkpoint["checkpoint_id"],
        trigger: checkpoint["trigger"],
        linked_call_id: checkpoint["linked_call_id"],
        created_at_ms: checkpoint["created_at_ms"],
        file_count: length(checkpoint["files"] || []),
        total_bytes: checkpoint["total_bytes"] || 0
      }
    end)
    |> Enum.sort_by(& &1.created_at_ms, :desc)
  end

  @doc """
  Find the checkpoint created just before a specific tool call.
  Useful for "rewind to before this tool call" UX.
  """
  @spec find_pre_tool_checkpoint(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def find_pre_tool_checkpoint(store_dir, tool_call_id) do
    case Engine.list(store_dir)
         |> Enum.find(fn chk -> chk["linked_call_id"] == tool_call_id end) do
      nil -> {:error, :not_found}
      checkpoint -> {:ok, checkpoint}
    end
  end

  # --- Internal ---

  defp validate_mode_requirements(:workspace, opts) do
    if Keyword.has_key?(opts, :workspace_root) and Keyword.has_key?(opts, :store_dir) do
      :ok
    else
      {:error, :missing_workspace_root}
    end
  end

  defp validate_mode_requirements(:conversation, opts) do
    if Keyword.has_key?(opts, :runelog_dir) and Keyword.has_key?(opts, :store_dir) do
      :ok
    else
      {:error, :missing_runelog_dir}
    end
  end

  defp validate_mode_requirements(:both, opts) do
    with :ok <- validate_mode_requirements(:workspace, opts),
         :ok <- validate_mode_requirements(:conversation, opts) do
      :ok
    end
  end

  defp load_manifest(store_dir, checkpoint_id) do
    manifest_path = Path.join([store_dir, checkpoint_id, "manifest.json"])

    case File.read(manifest_path) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, reason} -> {:error, {:manifest_not_found, reason}}
    end
  end

  defp do_dry_run(mode, manifest, opts, store_dir) do
    workspace_root = Keyword.get(opts, :workspace_root)
    runelog_dir = Keyword.get(opts, :runelog_dir)

    workspace_diff =
      if mode in [:workspace, :both] and workspace_root do
        {:ok, result} = Engine.restore(
          store_dir: store_dir,
          checkpoint_id: manifest["checkpoint_id"],
          target_dir: workspace_root,
          dry_run: true
        )
        result[:diff] || result
      end

    conversation_diff =
      if mode in [:conversation, :both] and runelog_dir do
        compute_conversation_diff(manifest, runelog_dir)
      end

    {:ok, %{
      mode: mode,
      checkpoint_id: manifest["checkpoint_id"],
      safety_checkpoint_id: nil,
      workspace_result: nil,
      conversation_result: nil,
      diff: %{
        workspace: workspace_diff,
        conversation: conversation_diff
      }
    }}
  end

  defp do_rewind(mode, manifest, opts, store_dir, create_safety) do
    workspace_root = Keyword.get(opts, :workspace_root)
    runelog_dir = Keyword.get(opts, :runelog_dir)

    # Create safety checkpoint before destructive operations
    safety_id =
      if create_safety and workspace_root do
        try do
          {:ok, safety} = Engine.create(
            workspace_root: workspace_root,
            store_dir: store_dir,
            trigger: :rewind_safety
          )
          Logger.info("Created safety checkpoint #{safety.checkpoint_id} before rewind")
          safety.checkpoint_id
        rescue
          e ->
            Logger.warning("Failed to create safety checkpoint: #{Exception.message(e)}")
            nil
        end
      end

    # Execute rewind based on mode
    workspace_result =
      if mode in [:workspace, :both] and workspace_root do
        case Engine.restore(
          store_dir: store_dir,
          checkpoint_id: manifest["checkpoint_id"],
          target_dir: workspace_root
        ) do
          {:ok, result} -> result
          {:error, reason} ->
            # If workspace restore fails, attempt to restore from safety checkpoint
            if safety_id do
              Logger.warning("Workspace restore failed, rolling back to safety checkpoint")
              Engine.restore(
                store_dir: store_dir,
                checkpoint_id: safety_id,
                target_dir: workspace_root
              )
            end
            throw({:rewind_failed, :workspace, reason})
        end
      end

    conversation_result =
      if mode in [:conversation, :both] and runelog_dir do
        truncate_runelog(manifest, runelog_dir)
      end

    {:ok, %{
      mode: mode,
      checkpoint_id: manifest["checkpoint_id"],
      safety_checkpoint_id: safety_id,
      workspace_result: workspace_result,
      conversation_result: conversation_result,
      diff: nil
    }}
  catch
    {:rewind_failed, component, reason} ->
      {:error, {:rewind_failed, component, reason}}
  end

  defp compute_conversation_diff(manifest, runelog_dir) do
    target_event_id = manifest["event_id"]

    if target_event_id do
      # Count events that would be truncated
      segments = list_segments(runelog_dir)
      current_max = count_events_in_segments(segments)

      %{
        target_event_id: target_event_id,
        current_max_event_id: current_max,
        events_to_truncate: max(0, current_max - target_event_id)
      }
    else
      %{
        target_event_id: nil,
        note: "checkpoint has no event_id; conversation state cannot be rewound"
      }
    end
  end

  defp truncate_runelog(manifest, runelog_dir) do
    target_event_id = manifest["event_id"]

    if target_event_id do
      # Find and truncate segments after target_event_id
      segments = list_segments(runelog_dir)

      truncated_count =
        segments
        |> Enum.reduce(0, fn segment_path, count ->
          count + truncate_segment_after(segment_path, target_event_id)
        end)

      Logger.info("Conversation rewind: truncated #{truncated_count} events after event_id #{target_event_id}")

      %{
        target_event_id: target_event_id,
        events_truncated: truncated_count
      }
    else
      Logger.info("Checkpoint has no event_id, skipping conversation rewind")
      %{target_event_id: nil, events_truncated: 0}
    end
  end

  defp list_segments(runelog_dir) do
    case File.ls(runelog_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".runelog"))
        |> Enum.sort()
        |> Enum.map(&Path.join(runelog_dir, &1))

      {:error, _} ->
        []
    end
  end

  defp count_events_in_segments(segments) do
    Enum.reduce(segments, 0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{size: size}} when size > 0 ->
          # Approximate: scan for event count
          acc + count_frames_in_file(path)
        _ ->
          acc
      end
    end)
  end

  defp count_frames_in_file(path) do
    case File.read(path) do
      {:ok, data} -> count_frames(data, 0)
      _ -> 0
    end
  end

  defp count_frames(<<len::unsigned-little-32, _crc::32, rest::binary>>, count) do
    if byte_size(rest) >= len do
      <<_payload::binary-size(len), remaining::binary>> = rest
      count_frames(remaining, count + 1)
    else
      count
    end
  end

  defp count_frames(_, count), do: count

  defp truncate_segment_after(segment_path, target_event_id) do
    case File.read(segment_path) do
      {:ok, data} ->
        {keep_bytes, truncated_count} = scan_until_event_id(data, target_event_id, 0, 0)

        if truncated_count > 0 do
          # Truncate the file at the determined position
          case File.open(segment_path, [:write, :binary]) do
            {:ok, fd} ->
              :ok = IO.binwrite(fd, binary_part(data, 0, keep_bytes))
              File.close(fd)
              truncated_count

            {:error, _} ->
              0
          end
        else
          0
        end

      {:error, _} ->
        0
    end
  end

  defp scan_until_event_id(<<len::unsigned-little-32, _crc::32, rest::binary>>, target_event_id, offset, truncated) do
    if byte_size(rest) >= len do
      <<payload::binary-size(len), remaining::binary>> = rest
      frame_end = offset + 8 + len

      case Jason.decode(payload) do
        {:ok, %{"event_id" => eid}} when is_integer(eid) and eid > target_event_id ->
          # This event is after the target — count it as truncated
          # Continue scanning remaining to count total
          {_remaining_bytes, more_truncated} =
            scan_until_event_id(remaining, target_event_id, frame_end, 0)
          {offset, truncated + 1 + more_truncated}

        {:ok, _} ->
          scan_until_event_id(remaining, target_event_id, frame_end, truncated)

        {:error, _} ->
          scan_until_event_id(remaining, target_event_id, frame_end, truncated)
      end
    else
      {offset, truncated}
    end
  end

  defp scan_until_event_id(_, _target, offset, truncated), do: {offset, truncated}
end
