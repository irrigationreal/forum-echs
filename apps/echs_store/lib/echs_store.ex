defmodule EchsStore do
  @moduledoc """
  SQLite-backed persistence for ECHS.

  This app is intentionally small: it stores thread metadata, message metadata,
  and the append-only history items that make up a thread. The runtime (`echs_core`)
  uses it to survive daemon restarts.
  """

  alias EchsStore.{Conversations, History, Messages, Repo, Threads}

  @spec enabled?() :: boolean()
  def enabled? do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defdelegate migrate(), to: EchsStore.Migrator

  defdelegate upsert_thread(attrs), to: Threads
  defdelegate get_thread(thread_id), to: Threads
  defdelegate list_threads(opts \\ []), to: Threads
  defdelegate set_thread_conversation(thread_id, conversation_id), to: Threads
  defdelegate list_threads_for_conversation(conversation_id), to: Threads

  defdelegate upsert_conversation(attrs), to: Conversations
  defdelegate get_conversation(conversation_id), to: Conversations
  defdelegate list_conversations(opts \\ []), to: Conversations

  defdelegate update_conversation_active_thread(conversation_id, thread_id),
    to: Conversations,
    as: :update_active_thread

  defdelegate upsert_message(thread_id, message_id, attrs), to: Messages
  defdelegate get_message(thread_id, message_id), to: Messages
  defdelegate list_messages(thread_id, opts \\ []), to: Messages
  defdelegate list_queued_messages(thread_id), to: Messages
  defdelegate mark_incomplete_messages(thread_id, opts \\ []), to: Messages

  defdelegate append_items(thread_id, message_id, items), to: History
  defdelegate get_slice(thread_id, offset, limit), to: History
  defdelegate get_by_message(thread_id, message_id), to: History
  defdelegate load_all(thread_id), to: History
end
