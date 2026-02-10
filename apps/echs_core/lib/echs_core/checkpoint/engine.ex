defmodule EchsCore.Checkpoint.Engine do
  @moduledoc """
  Workspace checkpoint engine: snapshot and restore file trees.

  Captures the workspace state (files + metadata) at a point in time
  and stores it for later restoration. Supports:

  - Full snapshots (all files in workspace)
  - Incremental snapshots (only changed files since last checkpoint)
  - Content-addressed storage (dedup identical files)
  - Exact restore (byte-identical to original)

  ## Auto-Checkpoint

  The engine integrates with the tool system to automatically create
  checkpoints before side-effectful tool invocations (bd-0046).

  Checkpoint -> tool_call linkage enables "rewind to before this tool call".
  """

  require Logger

  @type checkpoint :: %{
          checkpoint_id: String.t(),
          workspace_root: String.t(),
          event_id: non_neg_integer() | nil,
          linked_call_id: String.t() | nil,
          trigger: :manual | :auto_pre_tool | :policy,
          files: [file_entry()],
          created_at_ms: non_neg_integer(),
          total_bytes: non_neg_integer()
        }

  @type file_entry :: %{
          path: String.t(),
          content_hash: binary(),
          size: non_neg_integer(),
          mode: non_neg_integer(),
          mtime: non_neg_integer()
        }

  @doc """
  Create a checkpoint of the workspace.

  Options:
    * `:workspace_root` — root directory to snapshot (required)
    * `:store_dir` — directory for checkpoint storage (required)
    * `:event_id` — current runelog event_id (optional)
    * `:linked_call_id` — tool call this checkpoint precedes (optional)
    * `:trigger` — what triggered this checkpoint (default: :manual)
    * `:exclude_patterns` — glob patterns to exclude (default: common ignores)
  """
  @spec create(keyword()) :: {:ok, checkpoint()} | {:error, term()}
  def create(opts) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    store_dir = Keyword.fetch!(opts, :store_dir)
    trigger = Keyword.get(opts, :trigger, :manual)
    exclude_patterns = Keyword.get(opts, :exclude_patterns, default_excludes())

    checkpoint_id = generate_checkpoint_id()
    checkpoint_dir = Path.join(store_dir, checkpoint_id)
    File.mkdir_p!(checkpoint_dir)

    files = scan_workspace(workspace_root, exclude_patterns)

    {stored_files, total_bytes} =
      Enum.map_reduce(files, 0, fn file_info, acc ->
        content_hash = file_info.content_hash
        hash_hex = Base.encode16(content_hash, case: :lower)
        blob_dir = Path.join(store_dir, "blobs")
        File.mkdir_p!(blob_dir)
        blob_path = Path.join(blob_dir, hash_hex)

        # Content-addressed: only store if blob doesn't exist
        unless File.exists?(blob_path) do
          src_path = Path.join(workspace_root, file_info.path)
          File.cp!(src_path, blob_path)
        end

        entry = %{
          path: file_info.path,
          content_hash: hash_hex,
          size: file_info.size,
          mode: file_info.mode,
          mtime: file_info.mtime
        }

        {entry, acc + file_info.size}
      end)

    checkpoint = %{
      checkpoint_id: checkpoint_id,
      workspace_root: workspace_root,
      event_id: Keyword.get(opts, :event_id),
      linked_call_id: Keyword.get(opts, :linked_call_id),
      trigger: trigger,
      files: stored_files,
      created_at_ms: System.system_time(:millisecond),
      total_bytes: total_bytes
    }

    # Write manifest
    manifest_path = Path.join(checkpoint_dir, "manifest.json")
    File.write!(manifest_path, Jason.encode!(checkpoint, pretty: true))

    Logger.info(
      "Checkpoint #{checkpoint_id}: #{length(stored_files)} files, #{total_bytes} bytes"
    )

    {:ok, checkpoint}
  end

  @doc """
  Restore a checkpoint to the workspace.
  Produces a byte-identical workspace state (INV-CHECKPOINT-RESTORE).

  Options:
    * `:store_dir` — checkpoint storage directory (required)
    * `:checkpoint_id` — checkpoint to restore (required)
    * `:target_dir` — where to restore (defaults to original workspace_root)
    * `:dry_run` — if true, return diff without applying (default: false)
  """
  @spec restore(keyword()) :: {:ok, map()} | {:error, term()}
  def restore(opts) do
    store_dir = Keyword.fetch!(opts, :store_dir)
    checkpoint_id = Keyword.fetch!(opts, :checkpoint_id)
    dry_run = Keyword.get(opts, :dry_run, false)

    manifest_path = Path.join([store_dir, checkpoint_id, "manifest.json"])

    case File.read(manifest_path) do
      {:ok, json} ->
        checkpoint = Jason.decode!(json)
        target_dir = Keyword.get(opts, :target_dir, checkpoint["workspace_root"])

        if dry_run do
          diff = compute_diff(checkpoint, target_dir, store_dir)
          {:ok, %{checkpoint_id: checkpoint_id, diff: diff}}
        else
          do_restore(checkpoint, target_dir, store_dir)
        end

      {:error, reason} ->
        {:error, {:manifest_not_found, reason}}
    end
  end

  @doc """
  List all checkpoints in a store directory.
  """
  @spec list(String.t()) :: [map()]
  def list(store_dir) do
    case File.ls(store_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "chk_"))
        |> Enum.flat_map(fn dir ->
          manifest = Path.join([store_dir, dir, "manifest.json"])

          case File.read(manifest) do
            {:ok, json} -> [Jason.decode!(json)]
            _ -> []
          end
        end)
        |> Enum.sort_by(& &1["created_at_ms"])

      {:error, _} ->
        []
    end
  end

  @doc """
  Determine if a tool spec should trigger auto-checkpoint.
  """
  @spec should_auto_checkpoint?(map() | struct()) :: boolean()
  def should_auto_checkpoint?(%{side_effects: true, idempotent: false}), do: true
  def should_auto_checkpoint?(%{"side_effects" => true, "idempotent" => false}), do: true
  def should_auto_checkpoint?(_), do: false

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp scan_workspace(root, exclude_patterns) do
    root
    |> list_files_recursive()
    |> Enum.reject(fn path -> excluded?(path, exclude_patterns) end)
    |> Enum.flat_map(fn rel_path ->
      abs_path = Path.join(root, rel_path)

      case File.stat(abs_path) do
        {:ok, %{type: :regular, size: size, mode: mode, mtime: mtime}} ->
          content = File.read!(abs_path)
          hash = :crypto.hash(:sha256, content)

          [%{
            path: rel_path,
            content_hash: hash,
            size: size,
            mode: mode,
            mtime: mtime_to_ms(mtime)
          }]

        _ ->
          []
      end
    end)
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> list_files_recursive(path) |> Enum.map(&Path.join(entry, &1))
            true -> [entry]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp excluded?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      String.contains?(path, pattern)
    end)
  end

  defp default_excludes do
    [".git/", "node_modules/", "_build/", "deps/", ".elixir_ls/",
     "__pycache__/", ".pytest_cache/", "target/", ".DS_Store"]
  end

  defp do_restore(checkpoint, target_dir, store_dir) do
    File.mkdir_p!(target_dir)

    # Restore each file
    Enum.each(checkpoint["files"], fn file ->
      blob_path = Path.join([store_dir, "blobs", file["content_hash"]])
      target_path = Path.join(target_dir, file["path"])

      File.mkdir_p!(Path.dirname(target_path))
      File.cp!(blob_path, target_path)

      if file["mode"] do
        File.chmod!(target_path, file["mode"])
      end
    end)

    # Remove files that exist in target but not in checkpoint
    current_files = list_files_recursive(target_dir) |> MapSet.new()
    checkpoint_files = checkpoint["files"] |> Enum.map(& &1["path"]) |> MapSet.new()

    extra_files = MapSet.difference(current_files, checkpoint_files)

    Enum.each(extra_files, fn path ->
      abs_path = Path.join(target_dir, path)

      if not excluded?(path, default_excludes()) do
        File.rm(abs_path)
      end
    end)

    {:ok, %{
      checkpoint_id: checkpoint["checkpoint_id"],
      files_restored: length(checkpoint["files"]),
      files_removed: MapSet.size(extra_files)
    }}
  end

  defp compute_diff(checkpoint, target_dir, _store_dir) do
    checkpoint_files = checkpoint["files"] |> Map.new(& {&1["path"], &1})

    current_files =
      list_files_recursive(target_dir)
      |> Enum.flat_map(fn path ->
        abs = Path.join(target_dir, path)

        case File.read(abs) do
          {:ok, content} ->
            hash = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
            [{path, hash}]

          _ ->
            []
        end
      end)
      |> Map.new()

    added = Map.keys(checkpoint_files) -- Map.keys(current_files)
    removed = Map.keys(current_files) -- Map.keys(checkpoint_files)

    modified =
      for {path, hash} <- current_files,
          chk = Map.get(checkpoint_files, path),
          chk != nil,
          chk["content_hash"] != hash,
          do: path

    %{added: added, removed: removed, modified: modified}
  end

  defp generate_checkpoint_id do
    "chk_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp mtime_to_ms({{y, m, d}, {h, min, s}}) do
    NaiveDateTime.new!(y, m, d, h, min, s)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp mtime_to_ms(ts) when is_integer(ts), do: ts * 1000
  defp mtime_to_ms(_), do: 0
end
