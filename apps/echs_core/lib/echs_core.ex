defmodule EchsCore do
  @moduledoc """
  Public API for managing Codex threads and runtime state.
  """

  alias EchsCore.ThreadWorker

  @spec create_thread(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_thread(opts \\ []), do: ThreadWorker.create(opts)

  @spec send_message(String.t(), String.t() | [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def send_message(thread_id, content, opts \\ []),
    do: ThreadWorker.send_message(thread_id, content, opts)

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

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(thread_id), do: ThreadWorker.subscribe(thread_id)
end
