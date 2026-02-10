defmodule EchsCore.Rune.Migration do
  @moduledoc """
  Migration tool from v1 SQLite store (EchsStore) to v2 Runelog.

  Reads threads, messages, and history_items from the v1 SQLite database
  and writes them as properly typed runes to the v2 runelog.

  ## Usage

      {:ok, stats} = Migration.migrate_thread("thr_abc123",
        runelog_dir: "/path/to/runelogs",
        conversation_id: "conv_abc123"
      )

  ## Item Type Mapping

  | v1 item type | v2 rune kind |
  |---|---|
  | `"message"` (role: user) | `turn.started` |
  | `"message"` (role: assistant) | `turn.assistant_final` |
  | `"function_call"` | `tool.call` |
  | `"function_call_output"` | `tool.result` |
  | `"local_shell_call"` | `tool.call` |
  | (other) | `system.error` (with original item as context) |
  """

  require Logger

  alias EchsCore.Rune.{Schema, RunelogWriter}

  @doc """
  Migrate a single thread's history to a runelog.

  Options:
    * `:runelog_dir` — directory for the new runelog (required)
    * `:conversation_id` — conversation ID for the runes (defaults to thread_id)
    * `:agent_id` — agent ID (defaults to "agt_root")
  """
  @spec migrate_thread(String.t(), keyword()) ::
          {:ok, %{rune_count: non_neg_integer()}} | {:error, term()}
  def migrate_thread(thread_id, opts) do
    runelog_dir = Keyword.fetch!(opts, :runelog_dir)
    conversation_id = Keyword.get(opts, :conversation_id, thread_id)
    agent_id = Keyword.get(opts, :agent_id, "agt_root")

    case load_v1_history(thread_id) do
      {:ok, items} ->
        {:ok, writer} =
          RunelogWriter.start_link(
            dir: runelog_dir,
            conversation_id: conversation_id,
            fsync: :batch
          )

        # Emit session.created as first rune
        session_rune =
          Schema.new(
            conversation_id: conversation_id,
            kind: "session.created",
            payload: %{"config" => %{"migrated_from" => thread_id}},
            agent_id: agent_id
          )

        {:ok, _} = RunelogWriter.append(writer, session_rune)

        # Convert each v1 history item to runes
        rune_count =
          Enum.reduce(items, 1, fn item, count ->
            runes = v1_item_to_runes(item, conversation_id, agent_id)

            Enum.reduce(runes, count, fn rune, c ->
              case RunelogWriter.append(writer, rune) do
                {:ok, _} -> c + 1
                {:error, reason} ->
                  Logger.warning("Migration: failed to append rune: #{inspect(reason)}")
                  c
              end
            end)
          end)

        RunelogWriter.flush(writer)
        GenServer.stop(writer)

        Logger.info(
          "Migrated thread #{thread_id} -> conversation #{conversation_id}: #{rune_count} runes"
        )

        {:ok, %{rune_count: rune_count}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Migrate all threads in the v1 store.
  """
  @spec migrate_all(keyword()) :: {:ok, %{threads: non_neg_integer(), runes: non_neg_integer()}}
  def migrate_all(opts) do
    _runelog_dir = Keyword.fetch!(opts, :runelog_dir)

    threads =
      if EchsStore.enabled?() do
        case EchsStore.list_threads() do
          threads when is_list(threads) -> threads
          _ -> []
        end
      else
        []
      end

    results =
      Enum.map(threads, fn thread ->
        thread_id = thread.thread_id
        conv_id = "conv_" <> String.trim_leading(thread_id, "thr_")

        case migrate_thread(thread_id, Keyword.merge(opts, conversation_id: conv_id)) do
          {:ok, stats} -> {:ok, thread_id, stats}
          {:error, reason} -> {:error, thread_id, reason}
        end
      end)

    thread_count = Enum.count(results, &match?({:ok, _, _}, &1))
    rune_count = Enum.reduce(results, 0, fn
      {:ok, _, %{rune_count: n}}, acc -> acc + n
      _, acc -> acc
    end)

    {:ok, %{threads: thread_count, runes: rune_count}}
  end

  # -------------------------------------------------------------------
  # Internal: v1 history loading
  # -------------------------------------------------------------------

  defp load_v1_history(thread_id) do
    if EchsStore.enabled?() do
      EchsStore.load_all(thread_id)
    else
      {:error, :store_not_available}
    end
  end

  # -------------------------------------------------------------------
  # Internal: v1 item -> rune conversion
  # -------------------------------------------------------------------

  defp v1_item_to_runes(item, conversation_id, agent_id) do
    base_opts = [conversation_id: conversation_id, agent_id: agent_id]

    case item do
      %{"type" => "message", "role" => "user"} ->
        content = extract_content(item)
        [Schema.new(Keyword.merge(base_opts,
          kind: "turn.started",
          payload: %{"input" => content}
        ))]

      %{"type" => "message", "role" => "assistant"} ->
        content = extract_content(item)
        [Schema.new(Keyword.merge(base_opts,
          kind: "turn.assistant_final",
          payload: %{"content" => content}
        ))]

      %{"type" => "function_call"} ->
        call_id = item["call_id"] || item["id"] || generate_call_id()
        name = item["name"] || "unknown"
        arguments = item["arguments"] || %{}

        [Schema.new(Keyword.merge(base_opts,
          kind: "tool.call",
          payload: %{
            "call_id" => call_id,
            "tool_name" => name,
            "arguments" => arguments,
            "provenance" => "built_in"
          }
        ))]

      %{"type" => "function_call_output"} ->
        call_id = item["call_id"] || item["id"] || generate_call_id()
        output = item["output"] || ""

        [Schema.new(Keyword.merge(base_opts,
          kind: "tool.result",
          payload: %{
            "call_id" => call_id,
            "status" => "success",
            "output" => output
          }
        ))]

      %{"type" => "local_shell_call"} ->
        call_id = item["call_id"] || item["id"] || generate_call_id()
        action = item["action"] || %{}

        [Schema.new(Keyword.merge(base_opts,
          kind: "tool.call",
          payload: %{
            "call_id" => call_id,
            "tool_name" => "shell",
            "arguments" => action,
            "provenance" => "built_in"
          }
        ))]

      _ ->
        # Unknown item type — record as system error for debugging
        [Schema.new(Keyword.merge(base_opts,
          kind: "system.error",
          payload: %{
            "error_type" => "migration_unknown_item",
            "message" => "Unknown v1 item type: #{inspect(item["type"])}",
            "original_item" => item
          },
          visibility: :internal
        ))]
    end
  end

  defp extract_content(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} -> text
      %{"type" => "input_text", "text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp extract_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_content(_), do: ""

  defp generate_call_id do
    "migrated_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
