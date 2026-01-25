defmodule EchsCore do
  @moduledoc """
  Public API for managing Codex threads and runtime state.
  """

  alias EchsCore.StoreRestore
  alias EchsCore.ThreadWorker

  @spec create_thread(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_thread(opts \\ []), do: ThreadWorker.create(opts)

  @spec send_message(String.t(), String.t() | [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def send_message(thread_id, content, opts \\ []),
    do: ThreadWorker.send_message(thread_id, content, opts)

  @spec enqueue_message(String.t(), String.t() | [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def enqueue_message(thread_id, content, opts \\ []),
    do: ThreadWorker.enqueue_message(thread_id, content, opts)

  @spec list_messages(String.t(), keyword()) :: [map()]
  def list_messages(thread_id, opts \\ []),
    do: ThreadWorker.list_messages(thread_id, opts)

  @spec get_message(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_message(thread_id, message_id),
    do: ThreadWorker.get_message(thread_id, message_id)

  @spec get_message_items(String.t(), String.t(), keyword()) ::
          {:ok, %{message: map(), items: [map()]}} | {:error, :not_found}
  def get_message_items(thread_id, message_id, opts \\ []),
    do: ThreadWorker.get_message_items(thread_id, message_id, opts)

  @spec get_history(String.t(), keyword()) ::
          {:ok,
           %{
             total: non_neg_integer(),
             offset: non_neg_integer(),
             limit: non_neg_integer(),
             items: [map()]
           }}
  def get_history(thread_id, opts \\ []),
    do: ThreadWorker.get_history(thread_id, opts)

  @spec queue_message(String.t(), String.t() | [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def queue_message(thread_id, content, opts \\ []),
    do: ThreadWorker.send_message(thread_id, content, Keyword.put(opts, :mode, :queue))

  @spec steer_message(String.t(), String.t() | [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def steer_message(thread_id, content, opts \\ []),
    do: ThreadWorker.send_message(thread_id, content, Keyword.put(opts, :mode, :steer))

  @spec configure_thread(String.t(), map()) :: :ok
  def configure_thread(thread_id, config), do: ThreadWorker.configure(thread_id, config)

  @spec register_tool(String.t(), map(), ThreadWorker.tool_handler()) :: :ok | {:error, term()}
  def register_tool(thread_id, spec, handler), do: ThreadWorker.add_tool(thread_id, spec, handler)

  @spec unregister_tool(String.t(), String.t()) :: :ok
  def unregister_tool(thread_id, name), do: ThreadWorker.remove_tool(thread_id, name)

  @spec get_state(String.t()) :: ThreadWorker.state()
  def get_state(thread_id), do: ThreadWorker.get_state(thread_id)

  @spec pause_thread(String.t()) :: :ok
  def pause_thread(thread_id), do: ThreadWorker.pause(thread_id)

  @spec resume_thread(String.t()) :: :ok
  def resume_thread(thread_id), do: ThreadWorker.resume(thread_id)

  @spec interrupt_thread(String.t()) :: :ok
  def interrupt_thread(thread_id), do: ThreadWorker.interrupt(thread_id)

  @spec kill_thread(String.t()) :: :ok
  def kill_thread(thread_id), do: ThreadWorker.kill(thread_id)

  @doc """
  Restore a previously persisted thread from SQLite into a live `ThreadWorker`.

  This is used by `echs_server` to survive daemon restarts: the durable state
  lives in `echs_store`, and restoring rehydrates an in-memory worker so the
  thread can continue tool-loop execution.

  If the thread is already running, this is a no-op.
  """
  @spec restore_thread(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def restore_thread(thread_id, opts \\ []) do
    StoreRestore.restore_thread(thread_id, opts)
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(thread_id), do: ThreadWorker.subscribe(thread_id)
end
