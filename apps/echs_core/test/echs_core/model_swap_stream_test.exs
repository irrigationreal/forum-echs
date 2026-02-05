defmodule EchsCore.ModelSwapStreamTest do
  use ExUnit.Case, async: false

  alias EchsCore.ThreadWorker

  setup_all do
    Application.ensure_all_started(:echs_core)
    Application.ensure_all_started(:echs_codex)
    :ok
  end

  test "swaps GPT→Claude→GPT within a thread and emits consistent reasoning events" do
    {:ok, thread_id} = ThreadWorker.create()
    :ok = ThreadWorker.subscribe(thread_id)

    codex_events = [
      %{"type" => "response.output_text.delta", "delta" => "Hello"},
      %{"type" => "response.reasoning_summary.delta", "delta" => "Reason"},
      %{"type" => "response.reasoning_summary", "summary" => "Reason"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "name" => "shell",
          "arguments" => "{}",
          "call_id" => "call_1"
        }
      }
    ]

    {:ok, _} = ThreadWorker.test_apply_sse_events(thread_id, codex_events)
    stats = collect_events()
    assert stats.turn_delta > 0
    assert stats.reasoning_delta == 1
    assert stats.item_completed > 0

    :ok = ThreadWorker.configure(thread_id, %{"model" => "opus"})
    assert ThreadWorker.get_state(thread_id).model == "opus"

    claude_events =
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
        %{"type" => "message_stop"}
      ])

    {:ok, _} = ThreadWorker.test_apply_sse_events(thread_id, claude_events)
    stats = collect_events()
    assert stats.turn_delta > 0
    assert stats.reasoning_delta > 0

    :ok = ThreadWorker.configure(thread_id, %{"model" => "gpt-5.3-codex"})
    assert ThreadWorker.get_state(thread_id).model == "gpt-5.3-codex"

    {:ok, _} = ThreadWorker.test_apply_sse_events(thread_id, codex_events)
    stats = collect_events()
    assert stats.turn_delta > 0
    assert stats.reasoning_delta == 1

    summary_only = [%{"type" => "response.reasoning_summary", "summary" => "Summary"}]
    {:ok, _} = ThreadWorker.test_apply_sse_events(thread_id, summary_only)
    stats = collect_events()
    assert stats.reasoning_delta == 1
  end

  defp collect_events(stats \\ %{turn_delta: 0, reasoning_delta: 0, item_completed: 0}) do
    receive do
      {:turn_delta, _data} ->
        collect_events(%{stats | turn_delta: stats.turn_delta + 1})

      {:reasoning_delta, _data} ->
        collect_events(%{stats | reasoning_delta: stats.reasoning_delta + 1})

      {:item_completed, _data} ->
        collect_events(%{stats | item_completed: stats.item_completed + 1})

      _ ->
        collect_events(stats)
    after
      50 ->
        stats
    end
  end
end
