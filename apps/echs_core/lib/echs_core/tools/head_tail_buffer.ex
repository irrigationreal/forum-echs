defmodule EchsCore.Tools.HeadTailBuffer do
  @moduledoc false

  defstruct max_bytes: 0,
            head_budget: 0,
            tail_budget: 0,
            head: :queue.new(),
            tail: :queue.new(),
            head_bytes: 0,
            tail_bytes: 0,
            omitted_bytes: 0

  @type t :: %__MODULE__{}

  def new(max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    head_budget = div(max_bytes, 2)
    tail_budget = max_bytes - head_budget

    %__MODULE__{
      max_bytes: max_bytes,
      head_budget: head_budget,
      tail_budget: tail_budget,
      head: :queue.new(),
      tail: :queue.new(),
      head_bytes: 0,
      tail_bytes: 0,
      omitted_bytes: 0
    }
  end

  def retained_bytes(%__MODULE__{} = buffer) do
    buffer.head_bytes + buffer.tail_bytes
  end

  def omitted_bytes(%__MODULE__{} = buffer) do
    buffer.omitted_bytes
  end

  def push_chunk(%__MODULE__{} = buffer, chunk) when is_binary(chunk) do
    if buffer.max_bytes == 0 do
      %{buffer | omitted_bytes: buffer.omitted_bytes + byte_size(chunk)}
    else
      if buffer.head_bytes < buffer.head_budget do
        remaining_head = buffer.head_budget - buffer.head_bytes

        if byte_size(chunk) <= remaining_head do
          head = :queue.in(chunk, buffer.head)

          %{
            buffer
            | head: head,
              head_bytes: buffer.head_bytes + byte_size(chunk)
          }
        else
          <<head_part::binary-size(remaining_head), tail_part::binary>> = chunk

          buffer =
            if head_part == "" do
              buffer
            else
              %{
                buffer
                | head: :queue.in(head_part, buffer.head),
                  head_bytes: buffer.head_bytes + byte_size(head_part)
              }
            end

          push_to_tail(buffer, tail_part)
        end
      else
        push_to_tail(buffer, chunk)
      end
    end
  end

  def drain_chunks(%__MODULE__{} = buffer) do
    head_chunks = :queue.to_list(buffer.head)
    tail_chunks = :queue.to_list(buffer.tail)

    {
      head_chunks ++ tail_chunks,
      %{
        buffer
        | head: :queue.new(),
          tail: :queue.new(),
          head_bytes: 0,
          tail_bytes: 0,
          omitted_bytes: 0
      }
    }
  end

  def to_bytes(%__MODULE__{} = buffer) do
    head_chunks = :queue.to_list(buffer.head)
    tail_chunks = :queue.to_list(buffer.tail)
    IO.iodata_to_binary(head_chunks ++ tail_chunks)
  end

  defp push_to_tail(%__MODULE__{} = buffer, chunk) do
    if buffer.tail_budget == 0 do
      %{buffer | omitted_bytes: buffer.omitted_bytes + byte_size(chunk)}
    else
      if byte_size(chunk) >= buffer.tail_budget do
        start = byte_size(chunk) - buffer.tail_budget
        kept = binary_part(chunk, start, byte_size(chunk) - start)
        dropped = byte_size(chunk) - byte_size(kept)

        %{
          buffer
          | tail: :queue.in(kept, :queue.new()),
            tail_bytes: byte_size(kept),
            omitted_bytes: buffer.omitted_bytes + buffer.tail_bytes + dropped
        }
      else
        tail = :queue.in(chunk, buffer.tail)
        buffer = %{buffer | tail: tail, tail_bytes: buffer.tail_bytes + byte_size(chunk)}
        trim_tail_to_budget(buffer)
      end
    end
  end

  defp trim_tail_to_budget(%__MODULE__{} = buffer) do
    excess = buffer.tail_bytes - buffer.tail_budget

    if excess <= 0 do
      buffer
    else
      {tail, tail_bytes, omitted} = trim_tail_loop(buffer.tail, buffer.tail_bytes, excess)

      %{buffer | tail: tail, tail_bytes: tail_bytes, omitted_bytes: buffer.omitted_bytes + omitted}
    end
  end

  defp trim_tail_loop(tail, tail_bytes, excess) do
    case :queue.out(tail) do
      {{:value, front}, rest} ->
        front_size = byte_size(front)

        cond do
          excess >= front_size ->
            {tail_out, tail_bytes_out, omitted} =
              trim_tail_loop(rest, tail_bytes - front_size, excess - front_size)

            {tail_out, tail_bytes_out, omitted + front_size}

          true ->
            <<_drop::binary-size(excess), kept::binary>> = front
            tail = :queue.in_r(kept, rest)
            {tail, tail_bytes - excess, excess}
        end

      {:empty, _} ->
        {tail, tail_bytes, 0}
    end
  end
end
