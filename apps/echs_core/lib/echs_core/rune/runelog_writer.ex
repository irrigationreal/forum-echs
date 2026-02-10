defmodule EchsCore.Rune.RunelogWriter do
  @moduledoc """
  Append-only segment writer for the Runelog.

  Writes runes as length-prefixed, CRC32C-checksummed frames to segment
  files. Provides crash-safe recovery by truncating partial tail frames
  on open.

  ## Frame Format

      ┌──────────┬──────────┬──────────────────────┬──────────┐
      │ len (4B) │ CRC (4B) │ payload (len bytes)   │          │
      │ uint32le │ uint32le │ JSON-encoded rune     │ (next…)  │
      └──────────┴──────────┴──────────────────────┴──────────┘

  - `len`: byte length of the JSON payload (uint32 little-endian)
  - `CRC`: CRC32C of the JSON payload bytes (uint32 little-endian)
  - `payload`: JSON-encoded rune map

  ## Crash Safety

  On open, the writer scans the active segment from the beginning and
  truncates any partial tail frame. This handles the case where the
  process was killed mid-write.

  ## Configuration

  - `:dir` — directory for segment files (required)
  - `:conversation_id` — conversation this writer belongs to (required)
  - `:fsync` — fsync strategy: `:every` (every append), `:batch` (on flush),
    `:none` (never). Default: `:batch`
  - `:max_segment_bytes` — max segment size before rotation (default: 64 MiB)
  """

  use GenServer
  require Logger

  alias EchsCore.Rune.Schema

  @frame_header_size 8  # 4 bytes len + 4 bytes CRC
  @default_max_segment_bytes 64 * 1024 * 1024  # 64 MiB
  @default_fsync :batch

  defstruct [
    :dir,
    :conversation_id,
    :fd,
    :segment_path,
    :segment_start_event_id,
    :current_offset,
    :last_event_id,
    :fsync,
    :max_segment_bytes
  ]

  @type t :: %__MODULE__{}

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Start the writer GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Append a rune to the runelog. Assigns the next monotonic event_id.
  Returns `{:ok, event_id}` or `{:error, reason}`.
  """
  @spec append(GenServer.server(), Schema.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(writer, %Schema{} = rune) do
    GenServer.call(writer, {:append, rune})
  end

  @doc """
  Append a batch of runes atomically. Assigns consecutive event_ids.
  Returns `{:ok, first_event_id..last_event_id}` or `{:error, reason}`.
  """
  @spec append_batch(GenServer.server(), [Schema.t()]) ::
          {:ok, Range.t()} | {:error, term()}
  def append_batch(writer, runes) when is_list(runes) do
    GenServer.call(writer, {:append_batch, runes})
  end

  @doc """
  Flush buffered writes and optionally fsync.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(writer) do
    GenServer.call(writer, :flush)
  end

  @doc """
  Get the last event_id written.
  """
  @spec last_event_id(GenServer.server()) :: non_neg_integer()
  def last_event_id(writer) do
    GenServer.call(writer, :last_event_id)
  end

  @doc """
  Get the current segment path.
  """
  @spec segment_path(GenServer.server()) :: String.t()
  def segment_path(writer) do
    GenServer.call(writer, :segment_path)
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    fsync = Keyword.get(opts, :fsync, @default_fsync)
    max_seg = Keyword.get(opts, :max_segment_bytes, @default_max_segment_bytes)

    File.mkdir_p!(dir)

    {segment_path, start_eid, last_eid, offset, fd} =
      recover_or_create_segment(dir, conversation_id)

    state = %__MODULE__{
      dir: dir,
      conversation_id: conversation_id,
      fd: fd,
      segment_path: segment_path,
      segment_start_event_id: start_eid,
      current_offset: offset,
      last_event_id: last_eid,
      fsync: fsync,
      max_segment_bytes: max_seg
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:append, rune}, _from, state) do
    next_eid = state.last_event_id + 1
    rune = %{rune | event_id: next_eid}

    case write_frame(state.fd, rune) do
      {:ok, bytes_written} ->
        state = maybe_fsync_every(state)
        state = %{state | last_event_id: next_eid, current_offset: state.current_offset + bytes_written}
        state = maybe_rotate(state)
        {:reply, {:ok, next_eid}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append_batch, []}, _from, state) do
    {:reply, {:ok, state.last_event_id..state.last_event_id//1}, state}
  end

  def handle_call({:append_batch, runes}, _from, state) do
    first_eid = state.last_event_id + 1

    {result, state} =
      Enum.reduce_while(runes, {:ok, state}, fn rune, {:ok, acc_state} ->
        next_eid = acc_state.last_event_id + 1
        rune = %{rune | event_id: next_eid}

        case write_frame(acc_state.fd, rune) do
          {:ok, bytes_written} ->
            acc_state = %{acc_state |
              last_event_id: next_eid,
              current_offset: acc_state.current_offset + bytes_written
            }
            {:cont, {:ok, acc_state}}

          {:error, reason} ->
            {:halt, {{:error, reason}, acc_state}}
        end
      end)

    case result do
      :ok ->
        state = maybe_fsync_every(state)
        state = maybe_rotate(state)
        last_eid = state.last_event_id
        {:reply, {:ok, first_eid..last_eid//1}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    do_fsync(state.fd)
    {:reply, :ok, state}
  end

  def handle_call(:last_event_id, _from, state) do
    {:reply, state.last_event_id, state}
  end

  def handle_call(:segment_path, _from, state) do
    {:reply, state.segment_path, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.fd do
      do_fsync(state.fd)
      File.close(state.fd)
    end
  end

  # -------------------------------------------------------------------
  # Frame I/O
  # -------------------------------------------------------------------

  defp write_frame(fd, %Schema{} = rune) do
    json = Schema.encode_json!(rune)
    len = byte_size(json)
    crc = :erlang.crc32(json)

    frame =
      <<len::unsigned-little-32, crc::unsigned-little-32>> <> json

    case IO.binwrite(fd, frame) do
      :ok -> {:ok, byte_size(frame)}
      error -> error
    end
  end

  # -------------------------------------------------------------------
  # Segment management
  # -------------------------------------------------------------------

  defp segment_filename(conversation_id, start_event_id) do
    "#{conversation_id}_#{String.pad_leading(Integer.to_string(start_event_id), 16, "0")}.seg"
  end

  defp recover_or_create_segment(dir, conversation_id) do
    segments = list_segments(dir, conversation_id)

    case segments do
      [] ->
        create_new_segment(dir, conversation_id, 0)

      _ ->
        {latest_path, latest_start_eid} = List.last(segments)
        recover_segment(latest_path, latest_start_eid)
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
          # Extract start_event_id from filename
          start_str =
            filename
            |> String.trim_leading(prefix)
            |> String.trim_trailing(".seg")

          {start_eid, _} = Integer.parse(start_str)
          {Path.join(dir, filename), start_eid}
        end)

      {:error, _} ->
        []
    end
  end

  defp create_new_segment(dir, conversation_id, start_event_id) do
    filename = segment_filename(conversation_id, start_event_id)
    path = Path.join(dir, filename)
    {:ok, fd} = File.open(path, [:write, :binary, :raw])
    {path, start_event_id, max(start_event_id - 1, 0), 0, fd}
  end

  defp recover_segment(path, start_event_id) do
    {:ok, data} = File.read(path)
    {last_eid, valid_bytes} = scan_frames(data, start_event_id)

    # Truncate any partial tail
    total_size = byte_size(data)

    if valid_bytes < total_size do
      Logger.warning(
        "Runelog recovery: truncating #{total_size - valid_bytes} bytes from #{path}"
      )

      {:ok, fd} = File.open(path, [:write, :binary, :raw])
      :file.position(fd, valid_bytes)
      :file.truncate(fd)
      File.close(fd)
    end

    {:ok, fd} = File.open(path, [:append, :binary, :raw])
    {path, start_event_id, last_eid, valid_bytes, fd}
  end

  @doc false
  def scan_frames(data, start_event_id) do
    scan_frames_loop(data, 0, max(start_event_id - 1, 0))
  end

  defp scan_frames_loop(data, offset, last_eid) do
    remaining = byte_size(data) - offset

    if remaining < @frame_header_size do
      {last_eid, offset}
    else
      <<_::binary-size(offset), len::unsigned-little-32, crc::unsigned-little-32,
        _rest::binary>> = data

      if remaining < @frame_header_size + len do
        # Partial frame — truncate here
        {last_eid, offset}
      else
        <<_::binary-size(offset + @frame_header_size), payload::binary-size(len), _::binary>> =
          data

        computed_crc = :erlang.crc32(payload)

        if computed_crc != crc do
          # CRC mismatch — truncate from here
          Logger.warning("Runelog CRC mismatch at offset #{offset}, truncating")
          {last_eid, offset}
        else
          # Valid frame — extract event_id
          case Jason.decode(payload) do
            {:ok, %{"event_id" => eid}} when is_integer(eid) ->
              scan_frames_loop(data, offset + @frame_header_size + len, eid)

            _ ->
              # Can't extract event_id — treat as valid but keep last known eid
              scan_frames_loop(data, offset + @frame_header_size + len, last_eid)
          end
        end
      end
    end
  end

  defp maybe_rotate(%{current_offset: offset, max_segment_bytes: max} = state)
       when offset >= max do
    # Close current segment
    do_fsync(state.fd)
    File.close(state.fd)

    # Create new segment starting at next event_id
    next_start = state.last_event_id + 1
    {path, start_eid, _last_eid, file_offset, fd} =
      create_new_segment(state.dir, state.conversation_id, next_start)

    %{state |
      fd: fd,
      segment_path: path,
      segment_start_event_id: start_eid,
      current_offset: file_offset
    }
  end

  defp maybe_rotate(state), do: state

  defp maybe_fsync_every(%{fsync: :every} = state) do
    do_fsync(state.fd)
    state
  end

  defp maybe_fsync_every(state), do: state

  defp do_fsync(fd) when not is_nil(fd) do
    :file.sync(fd)
  end

  defp do_fsync(_), do: :ok
end
