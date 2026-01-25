defmodule EchsStore.Messages do
  @moduledoc false

  import Ecto.Query

  alias EchsStore.{Message, Repo}

  @spec upsert_message(String.t(), String.t(), map()) :: {:ok, Message.t()} | {:error, term()}
  def upsert_message(thread_id, message_id, attrs)
      when is_binary(thread_id) and is_binary(message_id) do
    changes =
      attrs
      |> Map.take([
        :status,
        :enqueued_at_ms,
        :started_at_ms,
        :completed_at_ms,
        :history_start,
        :history_end,
        :error,
        :request_json
      ])
      |> Map.put(:thread_id, thread_id)
      |> Map.put(:message_id, message_id)

    insert = struct(Message, changes)

    Repo.insert(insert,
      on_conflict: {:replace, Map.keys(changes) -- [:thread_id, :message_id]},
      conflict_target: [:thread_id, :message_id]
    )
    |> case do
      {:ok, _} -> {:ok, get_message!(thread_id, message_id)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec get_message(String.t(), String.t()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message(thread_id, message_id) do
    case Repo.get_by(Message, thread_id: thread_id, message_id: message_id) do
      nil -> {:error, :not_found}
      msg -> {:ok, msg}
    end
  end

  @spec get_message!(String.t(), String.t()) :: Message.t()
  def get_message!(thread_id, message_id) do
    Repo.get_by!(Message, thread_id: thread_id, message_id: message_id)
  end

  @spec list_messages(String.t(), keyword()) :: [Message.t()]
  def list_messages(thread_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50) |> clamp_int(1, 500)

    from(m in Message,
      where: m.thread_id == ^thread_id,
      order_by: [desc: m.enqueued_at_ms],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec list_queued_messages(String.t()) :: [Message.t()]
  def list_queued_messages(thread_id) do
    from(m in Message,
      where: m.thread_id == ^thread_id and m.status == "queued",
      order_by: [asc: m.enqueued_at_ms]
    )
    |> Repo.all()
  end

  @spec mark_incomplete_messages(String.t(), keyword()) :: non_neg_integer()
  def mark_incomplete_messages(thread_id, opts \\ []) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    status = Keyword.get(opts, :status, "error")
    error = Keyword.get(opts, :error, "daemon restarted")
    include_queued? = Keyword.get(opts, :include_queued, false)

    statuses =
      if include_queued? do
        ["queued", "running"]
      else
        ["running"]
      end

    from(m in Message,
      where: m.thread_id == ^thread_id and m.status in ^statuses
    )
    |> Repo.update_all(
      set: [
        status: status,
        completed_at_ms: now,
        error: error
      ]
    )
    |> elem(0)
  end

  defp clamp_int(value, min, max) when is_integer(value) do
    value |> min(max) |> max(min)
  end

  defp clamp_int(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> clamp_int(int, min, max)
      :error -> min
    end
  end

  defp clamp_int(_value, min, _max), do: min
end
