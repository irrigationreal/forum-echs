defmodule EchsStore.Conversations do
  @moduledoc false

  import Ecto.Query

  alias EchsStore.{Conversation, Repo}

  @spec upsert_conversation(map()) :: {:ok, Conversation.t()} | {:error, term()}
  def upsert_conversation(attrs) when is_map(attrs) do
    conversation_id = Map.fetch!(attrs, :conversation_id)

    changes =
      attrs
      |> Map.take([
        :conversation_id,
        :active_thread_id,
        :created_at_ms,
        :last_activity_at_ms,
        :model,
        :reasoning,
        :cwd,
        :instructions,
        :tools_json,
        :coordination_mode
      ])

    insert = struct(Conversation, changes)

    Repo.insert(insert,
      on_conflict: {:replace, Map.keys(changes) -- [:conversation_id]},
      conflict_target: :conversation_id
    )
    |> case do
      {:ok, _} -> {:ok, get_conversation!(conversation_id)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec get_conversation(String.t()) :: {:ok, Conversation.t()} | {:error, :not_found}
  def get_conversation(conversation_id) when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @spec get_conversation!(String.t()) :: Conversation.t()
  def get_conversation!(conversation_id), do: Repo.get!(Conversation, conversation_id)

  @spec list_conversations(keyword()) :: [Conversation.t()]
  def list_conversations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200) |> clamp_int(1, 2000)

    from(c in Conversation, order_by: [desc: c.last_activity_at_ms], limit: ^limit)
    |> Repo.all()
  end

  @spec update_active_thread(String.t(), String.t() | nil) ::
          {:ok, Conversation.t()} | {:error, term()}
  def update_active_thread(conversation_id, thread_id) when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation
        |> Ecto.Changeset.change(active_thread_id: thread_id, last_activity_at_ms: now_ms())
        |> Repo.update()
        |> case do
          {:ok, _} -> {:ok, get_conversation!(conversation_id)}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
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
