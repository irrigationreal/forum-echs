defmodule EchsStore.History do
  @moduledoc false

  import Ecto.Query

  alias EchsStore.{HistoryItem, Repo, Thread}

  @spec append_items(String.t(), String.t() | nil, [map()]) ::
          {:ok, %{start: non_neg_integer(), end: non_neg_integer()}} | {:error, term()}
  def append_items(thread_id, message_id, items)
      when is_binary(thread_id) and (is_binary(message_id) or is_nil(message_id)) and
             is_list(items) do
    Repo.transaction(fn ->
      thread = Repo.get!(Thread, thread_id)
      start = thread.history_count || 0

      # `timestamps(type: :utc_datetime_usec)` requires microsecond precision.
      now = DateTime.utc_now()

      to_insert =
        items
        |> Enum.with_index(start)
        |> Enum.map(fn {item, idx} ->
          %{
            thread_id: thread_id,
            idx: idx,
            message_id: message_id,
            item: item,
            inserted_at: now,
            updated_at: now
          }
        end)

      case to_insert do
        [] ->
          :ok

        rows ->
          Repo.insert_all(HistoryItem, rows)
      end

      finish = start + length(items)

      {:ok, _} =
        thread
        |> Ecto.Changeset.change(history_count: finish, last_activity_at_ms: now_ms())
        |> Repo.update()

      %{start: start, end: finish}
    end)
    |> case do
      {:ok, res} -> {:ok, res}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec get_slice(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok,
           %{
             total: non_neg_integer(),
             offset: non_neg_integer(),
             limit: pos_integer(),
             items: [map()]
           }}
          | {:error, :not_found}
  def get_slice(thread_id, offset, limit)
      when is_binary(thread_id) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit > 0 do
    case Repo.get(Thread, thread_id) do
      nil ->
        {:error, :not_found}

      thread ->
        items =
          from(h in HistoryItem,
            where: h.thread_id == ^thread_id,
            order_by: [asc: h.idx],
            offset: ^offset,
            limit: ^limit,
            select: h.item
          )
          |> Repo.all()

        {:ok, %{total: thread.history_count || 0, offset: offset, limit: limit, items: items}}
    end
  end

  @spec get_by_message(String.t(), String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_by_message(thread_id, message_id) when is_binary(thread_id) and is_binary(message_id) do
    case Repo.get(Thread, thread_id) do
      nil ->
        {:error, :not_found}

      _thread ->
        items =
          from(h in HistoryItem,
            where: h.thread_id == ^thread_id and h.message_id == ^message_id,
            order_by: [asc: h.idx],
            select: h.item
          )
          |> Repo.all()

        {:ok, items}
    end
  end

  @spec load_all(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def load_all(thread_id) when is_binary(thread_id) do
    case Repo.get(Thread, thread_id) do
      nil ->
        {:error, :not_found}

      _thread ->
        items =
          from(h in HistoryItem,
            where: h.thread_id == ^thread_id,
            order_by: [asc: h.idx],
            select: h.item
          )
          |> Repo.all()

        {:ok, items}
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
