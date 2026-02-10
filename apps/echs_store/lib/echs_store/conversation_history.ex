defmodule EchsStore.ConversationHistory do
  @moduledoc false

  import Ecto.Query

  alias EchsStore.{HistoryItem, Repo, Thread}

  @spec list_history(String.t(), keyword()) ::
          {:ok,
           %{conversation_id: String.t(), items: [map()], total: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}}
          | {:error, :not_found}
  def list_history(conversation_id, opts) when is_binary(conversation_id) do
    offset = Keyword.get(opts, :offset, 0) |> normalize_offset()
    limit = Keyword.get(opts, :limit, 500) |> normalize_limit()

    base =
      from(h in HistoryItem,
        join: t in Thread,
        on: t.thread_id == h.thread_id,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.created_at_ms, asc: t.thread_id, asc: h.idx],
        select: {t.thread_id, t.created_at_ms, h.item}
      )

    total =
      from([h, t] in base, select: count(h.idx))
      |> Repo.one()

    if is_integer(total) and total > 0 do
      rows =
        from([h, t] in base,
          offset: ^offset,
          limit: ^limit
        )
        |> Repo.all()

      items =
        rows
        |> Enum.reduce({[], nil}, fn {thread_id, created_at_ms, item}, {acc, last_thread} ->
          if last_thread != thread_id do
            marker = %{
              "type" => "session_break",
              "thread_id" => thread_id,
              "created_at_ms" => created_at_ms
            }

            {[item, marker | acc], thread_id}
          else
            {[item | acc], last_thread}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      {:ok,
       %{conversation_id: conversation_id, items: items, total: total, limit: limit, offset: offset}}
    else
      # No items; treat as not found so callers can distinguish empty vs missing if needed.
      {:error, :not_found}
    end
  end

  defp normalize_offset(value) when is_integer(value) and value >= 0, do: value
  defp normalize_offset(_), do: 0

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, 2000)
  defp normalize_limit(_), do: 500
end

