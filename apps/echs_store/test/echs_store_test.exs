defmodule EchsStoreTest do
  use ExUnit.Case, async: false

  test "threads, messages, and history items persist" do
    thread_id = "thr_test_" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _} =
      EchsStore.upsert_thread(%{
        thread_id: thread_id,
        parent_thread_id: nil,
        created_at_ms: System.system_time(:millisecond),
        last_activity_at_ms: System.system_time(:millisecond),
        model: "gpt-5.3-codex",
        reasoning: "medium",
        cwd: "/tmp",
        instructions: "hi",
        tools_json: Jason.encode!(["shell"]),
        coordination_mode: "hierarchical",
        history_count: 0
      })

    {:ok, _} =
      EchsStore.upsert_message(thread_id, "msg_1", %{
        status: "queued",
        enqueued_at_ms: System.system_time(:millisecond),
        request_json: Jason.encode!(%{"content" => "hello"})
      })

    {:ok, %{start: 0, end: 2}} =
      EchsStore.append_items(thread_id, "msg_1", [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "hi"}]
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "yo"}]
        }
      ])

    {:ok, %{total: 2, items: items}} = EchsStore.get_slice(thread_id, 0, 10)
    assert length(items) == 2

    {:ok, msg} = EchsStore.get_message(thread_id, "msg_1")
    assert msg.status == "queued"
  end
end
