defmodule EchsCore.LongConversationModelSwapTest do
  use ExUnit.Case, async: false

  alias EchsCore.ThreadWorker

  setup_all do
    Application.ensure_all_started(:echs_core)
    Application.ensure_all_started(:echs_codex)
    :ok
  end

  test "handles long history with multiple model swaps and deterministic events" do
    history_items = build_history_items(60)

    {:ok, thread_id} = ThreadWorker.create(history_items: history_items)
    :ok = ThreadWorker.subscribe(thread_id)

    assert length(ThreadWorker.get_state(thread_id).history_items) == length(history_items)

    run_swap(thread_id, "haiku", claude_events("toolu_haiku"), %{reasoning: :positive})

    run_swap(thread_id, "gpt-5.1-codex-mini", codex_events("call_mini"), %{reasoning: 1})

    run_swap(thread_id, "opus", claude_events("toolu_opus"), %{reasoning: :positive})

    run_swap(thread_id, "gpt-5.2-codex", codex_events("call_gpt"), %{reasoning: 1})

    assert length(ThreadWorker.get_state(thread_id).history_items) == length(history_items)
  end

  defp run_swap(thread_id, model, events, expectations) do
    flush_mailbox()
    :ok = ThreadWorker.configure(thread_id, %{"model" => model})
    assert ThreadWorker.get_state(thread_id).model == model
    flush_mailbox()

    {:ok, _} = ThreadWorker.test_apply_sse_events(thread_id, events)

    stats = collect_event_stats()
    assert stats.turn_delta > 0
    assert stats.item_completed == 1

    case Map.get(expectations, :reasoning) do
      :positive ->
        assert stats.reasoning_delta > 0

      expected when is_integer(expected) ->
        assert stats.reasoning_delta == expected
    end
  end

  defp codex_events(call_id) do
    [
      %{"type" => "response.output_text.delta", "delta" => "Hello"},
      %{"type" => "response.reasoning_summary.delta", "delta" => "Reason"},
      %{"type" => "response.reasoning_summary", "summary" => "Reason"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "name" => "shell",
          "arguments" => "{}",
          "call_id" => call_id
        }
      }
    ]
  end

  defp claude_events(call_id) do
    EchsClaude.test_normalize_events([
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "Plan "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "step1 "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "ok"}
      },
      %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{"type" => "tool_use", "name" => "shell", "id" => call_id}
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"command\":\"ls\"}"}
      },
      %{"type" => "content_block_stop", "index" => 2},
      %{"type" => "message_stop"}
    ])
  end

  defp collect_event_stats(stats \\ %{turn_delta: 0, reasoning_delta: 0, item_completed: 0}) do
    receive do
      {:turn_delta, _data} ->
        collect_event_stats(%{stats | turn_delta: stats.turn_delta + 1})

      {:reasoning_delta, _data} ->
        collect_event_stats(%{stats | reasoning_delta: stats.reasoning_delta + 1})

      {:item_completed, _data} ->
        collect_event_stats(%{stats | item_completed: stats.item_completed + 1})

      _ ->
        collect_event_stats(stats)
    after
      100 ->
        stats
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp build_history_items(pairs) when is_integer(pairs) and pairs > 0 do
    Enum.flat_map(1..pairs, fn idx ->
      [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "User #{idx}"}]
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Assistant #{idx}"}]
        }
      ]
    end)
  end
end
