defmodule EchsCore.ThreadWorker.Persistence do
  @moduledoc """
  Persistence functions for ThreadWorker: storing thread and message state
  to EchsStore. Write operations are buffered via EchsStore.WriteBuffer
  (cast-based, non-blocking) and flushed in batched transactions.
  """

  require Logger

  alias EchsCore.ThreadWorker.Config, as: TWConfig

  @doc """
  Builds a config summary map from thread state for broadcasting.
  """
  def config_summary(state) do
    %{
      model: state.model,
      reasoning: state.reasoning,
      cwd: state.cwd,
      tools: Enum.map(state.tools, fn t -> TWConfig.tool_key(t) end)
    }
  end

  @doc """
  Returns true if EchsStore is loaded and enabled.
  """
  def store_enabled? do
    Code.ensure_loaded?(EchsStore) and EchsStore.enabled?()
  end

  @doc """
  Persists thread state to the store via WriteBuffer.
  Returns :ok immediately (non-blocking).
  """
  def persist_thread(state) do
    if store_enabled?() do
      tools_json =
        try do
          Jason.encode!(state.tools)
        rescue
          Jason.EncodeError -> "[]"
        end

      EchsStore.WriteBuffer.buffer_thread(%{
        thread_id: state.thread_id,
        parent_thread_id: state.parent_thread_id,
        created_at_ms: state.created_at_ms,
        last_activity_at_ms: state.last_activity_at_ms,
        model: state.model,
        reasoning: state.reasoning,
        cwd: state.cwd,
        instructions: state.instructions,
        tools_json: tools_json,
        coordination_mode: Atom.to_string(state.coordination_mode),
        history_count: length(state.history_items)
      })
    else
      :ok
    end
  end

  @doc """
  Persists message state to the store via WriteBuffer.
  Returns :ok immediately (non-blocking).
  """
  def persist_message(state, message_id) when is_binary(message_id) and message_id != "" do
    if store_enabled?() do
      meta = Map.get(state.message_log, message_id)

      if is_map(meta) do
        EchsStore.WriteBuffer.buffer_message(state.thread_id, message_id, %{
          status: to_string(meta.status),
          enqueued_at_ms: meta.enqueued_at_ms,
          started_at_ms: meta.started_at_ms,
          completed_at_ms: meta.completed_at_ms,
          history_start: meta.history_start,
          history_end: meta.history_end,
          error: format_message_error(meta.error),
          request_json: meta.request_json
        })

        # Also buffer thread update (deduplicated by WriteBuffer)
        persist_thread(state)
      else
        :ok
      end
    else
      :ok
    end
  end

  def persist_message(_state, _message_id), do: :ok

  @doc """
  Formats an error value for persistence storage.
  """
  def format_message_error(nil), do: nil
  def format_message_error(err) when is_binary(err), do: err
  def format_message_error(err), do: inspect(err)
end
