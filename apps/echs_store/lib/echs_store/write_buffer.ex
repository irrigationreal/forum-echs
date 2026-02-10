defmodule EchsStore.WriteBuffer do
  @moduledoc """
  Batches thread and message upserts into single SQLite transactions.

  Accepts writes via cast (non-blocking) and flushes periodically (every
  `@flush_interval_ms`) or when `@max_buffer_size` items accumulate.

  Thread upserts are deduplicated by thread_id (latest wins).
  Message upserts are deduplicated by {thread_id, message_id} (latest wins).

  Call `flush/0` before reads that need consistency with recent writes.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @flush_interval_ms 50
  @max_buffer_size 100

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Buffer a thread upsert (non-blocking)."
  @spec buffer_thread(map()) :: :ok
  def buffer_thread(attrs) when is_map(attrs) do
    GenServer.cast(@name, {:thread, attrs})
  end

  @doc "Buffer a message upsert (non-blocking)."
  @spec buffer_message(String.t(), String.t(), map()) :: :ok
  def buffer_message(thread_id, message_id, attrs) do
    GenServer.cast(@name, {:message, thread_id, message_id, attrs})
  end

  @doc "Flush all buffered writes synchronously. Returns :ok when done."
  @spec flush() :: :ok
  def flush do
    GenServer.call(@name, :flush, 10_000)
  end

  # -------------------------------------------------------------------
  # GenServer
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, new_state()}
  end

  @impl true
  def handle_cast({:thread, attrs}, state) do
    thread_id = Map.fetch!(attrs, :thread_id)
    new_key? = not Map.has_key?(state.threads, thread_id)
    threads = Map.put(state.threads, thread_id, attrs)
    state = %{state | threads: threads, count: state.count + if(new_key?, do: 1, else: 0)}
    {:noreply, maybe_flush(state)}
  end

  def handle_cast({:message, thread_id, message_id, attrs}, state) do
    key = {thread_id, message_id}
    new_key? = not Map.has_key?(state.messages, key)
    messages = Map.put(state.messages, key, attrs)
    state = %{state | messages: messages, count: state.count + if(new_key?, do: 1, else: 0)}
    {:noreply, maybe_flush(state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    cancel_timer(state)
    do_flush(state)
    {:reply, :ok, new_state()}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.count > 0 do
      do_flush(state)
      {:noreply, new_state()}
    else
      {:noreply, schedule_tick(state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp new_state do
    %{threads: %{}, messages: %{}, count: 0}
    |> schedule_tick()
  end

  defp schedule_tick(state) do
    ref = Process.send_after(self(), :tick, @flush_interval_ms)
    Map.put(state, :timer, ref)
  end

  defp maybe_flush(state) do
    if state.count >= @max_buffer_size do
      cancel_timer(state)
      do_flush(state)
      new_state()
    else
      state
    end
  end

  defp cancel_timer(%{timer: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_timer(_), do: :ok

  defp do_flush(%{threads: threads, messages: messages}) when map_size(threads) == 0 and map_size(messages) == 0 do
    :ok
  end

  defp do_flush(%{threads: threads, messages: messages}) do
    EchsStore.Repo.transaction(fn ->
      # Upsert threads (deduplicated by thread_id)
      Enum.each(threads, fn {_id, attrs} ->
        case EchsStore.Threads.upsert_thread(attrs) do
          {:ok, _} -> :ok
          {:error, reason} -> EchsStore.Repo.rollback({:thread_upsert_failed, reason})
        end
      end)

      # Upsert messages (deduplicated by {thread_id, message_id})
      Enum.each(messages, fn {{thread_id, message_id}, attrs} ->
        case EchsStore.Messages.upsert_message(thread_id, message_id, attrs) do
          {:ok, _} -> :ok
          {:error, reason} -> EchsStore.Repo.rollback({:message_upsert_failed, reason})
        end
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("write_buffer flush failed: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("write_buffer flush error: #{Exception.message(e)}")
      :error
  end
end
