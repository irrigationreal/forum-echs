defmodule EchsStore.Threads do
  @moduledoc false

  import Ecto.Query

  alias EchsStore.{Repo, Thread}

  @spec upsert_thread(map()) :: {:ok, Thread.t()} | {:error, term()}
  def upsert_thread(attrs) when is_map(attrs) do
    thread_id = Map.fetch!(attrs, :thread_id)

    changes =
      attrs
      |> Map.take([
        :thread_id,
        :parent_thread_id,
        :created_at_ms,
        :last_activity_at_ms,
        :model,
        :reasoning,
        :cwd,
        :instructions,
        :tools_json,
        :coordination_mode,
        :history_count
      ])

    insert = struct(Thread, changes)

    Repo.insert(insert,
      on_conflict: {:replace, Map.keys(changes) -- [:thread_id]},
      conflict_target: :thread_id
    )
    |> case do
      {:ok, _} -> {:ok, get_thread!(thread_id)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec get_thread(String.t()) :: {:ok, Thread.t()} | {:error, :not_found}
  def get_thread(thread_id) when is_binary(thread_id) do
    case Repo.get(Thread, thread_id) do
      nil -> {:error, :not_found}
      thread -> {:ok, thread}
    end
  end

  @spec get_thread!(String.t()) :: Thread.t()
  def get_thread!(thread_id) do
    Repo.get!(Thread, thread_id)
  end

  @spec list_threads(keyword()) :: [Thread.t()]
  def list_threads(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200) |> clamp_int(1, 2000)

    from(t in Thread, order_by: [desc: t.last_activity_at_ms], limit: ^limit)
    |> Repo.all()
  end

  @spec bump_history_count(String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def bump_history_count(thread_id, delta)
      when is_binary(thread_id) and is_integer(delta) and delta >= 0 do
    Repo.transaction(fn ->
      thread = Repo.get!(Thread, thread_id)
      start = thread.history_count || 0
      finish = start + delta

      {:ok, _} =
        thread
        |> Ecto.Changeset.change(history_count: finish, last_activity_at_ms: now_ms())
        |> Repo.update()

      {start, finish}
    end)
    |> case do
      {:ok, {start, finish}} -> {:ok, start, finish}
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

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
