defmodule EchsCore.Rune.Snapshot do
  @moduledoc """
  Derived-state snapshots for the Runelog.

  Snapshots capture the derived state at a given event_id, enabling:
  - Fast conversation reload without replaying the full log
  - Compaction of old segments after snapshotting
  - Integrity checking via content-addressed hashing

  ## Storage Format

  Each snapshot is stored as a single file:
  `<conversation_id>_snap_<event_id>.snap`

  The file contains:
  1. Header: SHA-256 hash (32 bytes) + event_id (8 bytes) + payload_len (4 bytes)
  2. Payload: JSON-encoded derived state

  ## Content Addressing

  The SHA-256 hash covers the entire payload, ensuring integrity. On read,
  the hash is recomputed and compared. This satisfies INV-SNAPSHOT-INTEGRITY.
  """

  require Logger

  @header_size 44  # 32 (hash) + 8 (event_id) + 4 (payload_len)

  @type derived_state :: %{
          conversation_id: String.t(),
          event_id: non_neg_integer(),
          agent_states: map(),
          config: map(),
          plan: map() | nil,
          tools: [map()],
          metadata: map()
        }

  @doc """
  Write a snapshot to disk. Returns the snapshot path.
  """
  @spec write(String.t(), non_neg_integer(), derived_state(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def write(dir, event_id, state, _opts \\ []) do
    File.mkdir_p!(dir)
    conversation_id = state[:conversation_id] || state["conversation_id"] || "unknown"

    payload = Jason.encode!(state)
    hash = :crypto.hash(:sha256, payload)
    payload_len = byte_size(payload)

    header = hash <> <<event_id::unsigned-little-64, payload_len::unsigned-little-32>>
    data = header <> payload

    filename = snapshot_filename(conversation_id, event_id)
    path = Path.join(dir, filename)

    # Write to temp file then rename for atomicity
    tmp_path = path <> ".tmp"

    case File.write(tmp_path, data) do
      :ok ->
        File.rename!(tmp_path, path)
        {:ok, path}

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  @doc """
  Read and verify a snapshot from disk. Returns the derived state.
  Validates INV-SNAPSHOT-INTEGRITY.
  """
  @spec read(String.t()) :: {:ok, non_neg_integer(), derived_state()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, data} when byte_size(data) >= @header_size ->
        <<stored_hash::binary-32, event_id::unsigned-little-64,
          payload_len::unsigned-little-32, rest::binary>> = data

        if byte_size(rest) < payload_len do
          {:error, :truncated}
        else
          <<payload::binary-size(payload_len), _::binary>> = rest
          computed_hash = :crypto.hash(:sha256, payload)

          if computed_hash != stored_hash do
            {:error, :integrity_check_failed}
          else
            case Jason.decode(payload) do
              {:ok, state} -> {:ok, event_id, state}
              {:error, reason} -> {:error, {:decode_error, reason}}
            end
          end
        end

      {:ok, _} ->
        {:error, :truncated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all snapshots for a conversation in a directory, sorted by event_id.
  """
  @spec list(String.t(), String.t()) :: [{non_neg_integer(), String.t()}]
  def list(dir, conversation_id) do
    prefix = "#{conversation_id}_snap_"

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".snap")))
        |> Enum.map(fn filename ->
          eid_str =
            filename
            |> String.trim_leading(prefix)
            |> String.trim_trailing(".snap")

          {eid, _} = Integer.parse(eid_str)
          {eid, Path.join(dir, filename)}
        end)
        |> Enum.sort_by(&elem(&1, 0))

      {:error, _} ->
        []
    end
  end

  @doc """
  Find the latest snapshot for a conversation at or before a given event_id.
  """
  @spec latest(String.t(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer(), String.t()} | :none
  def latest(dir, conversation_id, max_event_id \\ :infinity) do
    snapshots = list(dir, conversation_id)

    filtered =
      if max_event_id == :infinity do
        snapshots
      else
        Enum.filter(snapshots, fn {eid, _} -> eid <= max_event_id end)
      end

    case List.last(filtered) do
      nil -> :none
      {eid, path} -> {:ok, eid, path}
    end
  end

  defp snapshot_filename(conversation_id, event_id) do
    "#{conversation_id}_snap_#{String.pad_leading(Integer.to_string(event_id), 16, "0")}.snap"
  end
end
