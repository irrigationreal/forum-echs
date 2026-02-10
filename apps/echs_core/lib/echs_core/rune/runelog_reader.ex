defmodule EchsCore.Rune.RunelogReader do
  @moduledoc """
  Sequential reader for Runelog segments with sparse index support.

  Provides:
  - Sequential iteration over runes in a segment
  - Sublinear seek via sparse index (every Nth event_id -> byte offset)
  - CRC32C validation on every read
  - Bounded backfill windows (read N runes starting from event_id)
  - Index rebuild from segment scan

  ## Usage

      {:ok, reader} = RunelogReader.open(segment_path)
      {:ok, reader} = RunelogReader.seek(reader, event_id: 42)
      {:ok, rune, reader} = RunelogReader.next(reader)
      :eof = RunelogReader.next(reader)  # when no more runes
      :ok = RunelogReader.close(reader)

  ## Sparse Index Format

  The index file (`.idx`) stores entries as 16-byte records:

      ┌──────────────┬──────────────┐
      │ event_id (8B)│ offset (8B)  │
      │ uint64le     │ uint64le     │
      └──────────────┴──────────────┘
  """

  alias EchsCore.Rune.Schema

  @frame_header_size 8
  @default_index_interval 256

  defstruct [
    :path,
    :data,
    :size,
    :offset,
    :index
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          data: binary(),
          size: non_neg_integer(),
          offset: non_neg_integer(),
          index: [{non_neg_integer(), non_neg_integer()}] | nil
        }

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Open a segment file for reading. Optionally loads the sparse index.
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ []) do
    case File.read(path) do
      {:ok, data} ->
        index =
          if Keyword.get(opts, :load_index, true) do
            load_index(index_path(path))
          end

        {:ok,
         %__MODULE__{
           path: path,
           data: data,
           size: byte_size(data),
           offset: 0,
           index: index
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read the next rune from the current position.
  Returns `{:ok, rune, reader}`, `{:error, reason, reader}`, or `:eof`.
  """
  @spec next(t()) :: {:ok, Schema.t(), t()} | {:error, term(), t()} | :eof
  def next(%__MODULE__{offset: offset, size: size}) when offset >= size do
    :eof
  end

  def next(%__MODULE__{data: data, offset: offset, size: size} = reader) do
    remaining = size - offset

    if remaining < @frame_header_size do
      :eof
    else
      <<_::binary-size(offset), len::unsigned-little-32, stored_crc::unsigned-little-32,
        _rest::binary>> = data

      if remaining < @frame_header_size + len do
        # Partial frame at end of file
        :eof
      else
        <<_::binary-size(offset + @frame_header_size), payload::binary-size(len), _::binary>> =
          data

        computed_crc = :erlang.crc32(payload)

        if computed_crc != stored_crc do
          {:error, {:crc_mismatch, offset},
           %{reader | offset: offset + @frame_header_size + len}}
        else
          case Schema.decode_json(payload) do
            {:ok, rune} ->
              {:ok, rune, %{reader | offset: offset + @frame_header_size + len}}

            {:error, reason} ->
              {:error, {:decode_error, reason},
               %{reader | offset: offset + @frame_header_size + len}}
          end
        end
      end
    end
  end

  @doc """
  Seek to a position in the segment.

  Options:
    * `event_id: N` — seek to the first rune with event_id >= N.
      Uses sparse index for sublinear seek when available.
    * `offset: N` — seek to byte offset N.
  """
  @spec seek(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def seek(reader, opts) do
    cond do
      Keyword.has_key?(opts, :offset) ->
        byte_offset = Keyword.fetch!(opts, :offset)
        {:ok, %{reader | offset: min(byte_offset, reader.size)}}

      Keyword.has_key?(opts, :event_id) ->
        target_eid = Keyword.fetch!(opts, :event_id)
        seek_to_event_id(reader, target_eid)

      true ->
        {:error, :invalid_seek_options}
    end
  end

  @doc """
  Read up to `limit` runes starting from the current position.
  """
  @spec read_batch(t(), non_neg_integer()) :: {[Schema.t()], t()}
  def read_batch(reader, limit) when limit > 0 do
    read_batch_loop(reader, limit, [])
  end

  def read_batch(reader, _limit), do: {[], reader}

  @doc """
  Read up to `limit` runes starting from `since_event_id` (exclusive).
  Useful for backfill/resume: returns runes with event_id > since_event_id.
  """
  @spec backfill(t(), non_neg_integer(), non_neg_integer()) :: {[Schema.t()], t()}
  def backfill(reader, since_event_id, limit) do
    case seek(reader, event_id: since_event_id + 1) do
      {:ok, reader} -> read_batch(reader, limit)
      {:error, _} -> {[], reader}
    end
  end

  @doc """
  Read all runes from the segment. Use with caution on large segments.
  """
  @spec read_all(t()) :: {[Schema.t()], t()}
  def read_all(reader) do
    reader = %{reader | offset: 0}
    read_batch_loop(reader, :infinity, [])
  end

  @doc """
  Close the reader (no-op for memory-mapped reads, provided for API symmetry).
  """
  @spec close(t()) :: :ok
  def close(_reader), do: :ok

  # -------------------------------------------------------------------
  # Sparse Index
  # -------------------------------------------------------------------

  @doc """
  Build a sparse index for a segment file.
  Writes the index to a `.idx` file alongside the segment.
  """
  @spec build_index(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def build_index(segment_path, opts \\ []) do
    interval = Keyword.get(opts, :interval, @default_index_interval)

    case open(segment_path, load_index: false) do
      {:ok, reader} ->
        {entries, _count} = build_index_entries(reader, interval)
        idx_path = index_path(segment_path)
        write_index(idx_path, entries)
        {:ok, length(entries)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rebuild the index by scanning the segment from the beginning.
  """
  @spec rebuild_index(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rebuild_index(segment_path, opts \\ []) do
    # Delete existing index first
    File.rm(index_path(segment_path))
    build_index(segment_path, opts)
  end

  # -------------------------------------------------------------------
  # Internal: seek
  # -------------------------------------------------------------------

  defp seek_to_event_id(reader, target_eid) do
    # Use sparse index if available for sublinear seek
    start_offset =
      case reader.index do
        nil ->
          0

        entries when is_list(entries) ->
          # Find the largest index entry with event_id <= target_eid
          case Enum.take_while(entries, fn {eid, _off} -> eid <= target_eid end) do
            [] -> 0
            found -> elem(List.last(found), 1)
          end
      end

    # Linear scan from start_offset to find first rune with event_id >= target_eid
    reader = %{reader | offset: start_offset}
    scan_to_event_id(reader, target_eid)
  end

  defp scan_to_event_id(reader, target_eid) do
    case next(reader) do
      {:ok, rune, new_reader} ->
        if rune.event_id >= target_eid do
          # Found it — rewind to this rune's start position
          # The rune was already read, so we need to use the reader state
          # before `next` was called. But we can't rewind easily, so instead
          # we return the reader positioned *at* this rune by backing up.
          frame_size = new_reader.offset - reader.offset
          {:ok, %{new_reader | offset: new_reader.offset - frame_size}}
        else
          scan_to_event_id(new_reader, target_eid)
        end

      :eof ->
        {:ok, reader}

      {:error, _reason, new_reader} ->
        scan_to_event_id(new_reader, target_eid)
    end
  end

  # -------------------------------------------------------------------
  # Internal: batch read
  # -------------------------------------------------------------------

  defp read_batch_loop(reader, 0, acc), do: {Enum.reverse(acc), reader}

  defp read_batch_loop(reader, remaining, acc) do
    case next(reader) do
      {:ok, rune, new_reader} ->
        next_remaining = if remaining == :infinity, do: :infinity, else: remaining - 1
        read_batch_loop(new_reader, next_remaining, [rune | acc])

      :eof ->
        {Enum.reverse(acc), reader}

      {:error, _reason, new_reader} ->
        # Skip corrupt frames
        next_remaining = if remaining == :infinity, do: :infinity, else: remaining
        read_batch_loop(new_reader, next_remaining, acc)
    end
  end

  # -------------------------------------------------------------------
  # Internal: index I/O
  # -------------------------------------------------------------------

  defp index_path(segment_path) do
    String.replace_trailing(segment_path, ".seg", ".idx")
  end

  defp load_index(path) do
    case File.read(path) do
      {:ok, data} ->
        parse_index(data, [])

      {:error, _} ->
        nil
    end
  end

  defp parse_index(<<>>, acc), do: Enum.reverse(acc)

  defp parse_index(
         <<eid::unsigned-little-64, offset::unsigned-little-64, rest::binary>>,
         acc
       ) do
    parse_index(rest, [{eid, offset} | acc])
  end

  defp parse_index(_partial, acc), do: Enum.reverse(acc)

  defp write_index(path, entries) do
    data =
      Enum.map(entries, fn {eid, offset} ->
        <<eid::unsigned-little-64, offset::unsigned-little-64>>
      end)

    File.write!(path, data)
  end

  defp build_index_entries(reader, interval) do
    build_index_loop(reader, interval, 0, [])
  end

  defp build_index_loop(reader, interval, count, acc) do
    frame_offset = reader.offset

    case next(reader) do
      {:ok, rune, new_reader} ->
        new_acc =
          if rem(count, interval) == 0 do
            [{rune.event_id, frame_offset} | acc]
          else
            acc
          end

        build_index_loop(new_reader, interval, count + 1, new_acc)

      :eof ->
        {Enum.reverse(acc), count}

      {:error, _reason, new_reader} ->
        build_index_loop(new_reader, interval, count, acc)
    end
  end
end
