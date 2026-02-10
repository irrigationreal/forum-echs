defmodule EchsStore.WriteBufferTest do
  use ExUnit.Case, async: false

  alias EchsStore.WriteBuffer

  setup do
    # Drain any buffered writes from previous tests so they don't
    # leak across test boundaries and cause foreign-key failures.
    _ = WriteBuffer.flush()
    :ok
  end

  describe "buffer_thread/1" do
    test "accepts thread attributes without error" do
      assert :ok =
               WriteBuffer.buffer_thread(%{
                 thread_id: "thr_wbtest_#{System.unique_integer([:positive])}",
                 model: "test-model",
                 reasoning: "medium",
                 cwd: "/tmp",
                 instructions: "test",
                 tools_json: "[]",
                 coordination_mode: "hierarchical",
                 history_count: 0,
                 created_at_ms: System.system_time(:millisecond),
                 last_activity_at_ms: System.system_time(:millisecond)
               })
    end
  end

  describe "buffer_message/3" do
    test "accepts message attributes without error" do
      thread_id = "thr_wbtest_#{System.unique_integer([:positive])}"

      # Buffer a thread first so the message won't violate the FK constraint
      # when the buffer is flushed (either by timer or a subsequent test).
      WriteBuffer.buffer_thread(%{
        thread_id: thread_id,
        model: "test-model",
        reasoning: "medium",
        cwd: "/tmp",
        instructions: "test",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 0,
        created_at_ms: System.system_time(:millisecond),
        last_activity_at_ms: System.system_time(:millisecond)
      })

      assert :ok =
               WriteBuffer.buffer_message(thread_id, "msg_test_1", %{
                 status: "queued",
                 enqueued_at_ms: System.system_time(:millisecond)
               })
    end
  end

  describe "flush/0" do
    test "synchronously flushes buffered writes" do
      thread_id = "thr_wbflush_#{System.unique_integer([:positive])}"

      WriteBuffer.buffer_thread(%{
        thread_id: thread_id,
        model: "test-model",
        reasoning: "medium",
        cwd: "/tmp",
        instructions: "flush test",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 0,
        created_at_ms: System.system_time(:millisecond),
        last_activity_at_ms: System.system_time(:millisecond)
      })

      # Flush should complete without error
      assert :ok = WriteBuffer.flush()

      # After flush, the thread should be in the store
      assert {:ok, thread} = EchsStore.get_thread(thread_id)
      assert thread.thread_id == thread_id
      assert thread.model == "test-model"
    end

    test "deduplicates thread writes (latest wins)" do
      thread_id = "thr_wbdedup_#{System.unique_integer([:positive])}"

      WriteBuffer.buffer_thread(%{
        thread_id: thread_id,
        model: "model-1",
        reasoning: "low",
        cwd: "/tmp",
        instructions: "first",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 0,
        created_at_ms: System.system_time(:millisecond),
        last_activity_at_ms: System.system_time(:millisecond)
      })

      WriteBuffer.buffer_thread(%{
        thread_id: thread_id,
        model: "model-2",
        reasoning: "high",
        cwd: "/tmp",
        instructions: "second",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 5,
        created_at_ms: System.system_time(:millisecond),
        last_activity_at_ms: System.system_time(:millisecond)
      })

      assert :ok = WriteBuffer.flush()

      assert {:ok, thread} = EchsStore.get_thread(thread_id)
      # Should have the latest values
      assert thread.model == "model-2"
      assert thread.reasoning == "high"
      assert thread.history_count == 5
    end

    test "flushes messages with threads" do
      thread_id = "thr_wbmsg_#{System.unique_integer([:positive])}"
      message_id = "msg_wbtest_1"

      WriteBuffer.buffer_thread(%{
        thread_id: thread_id,
        model: "test-model",
        reasoning: "medium",
        cwd: "/tmp",
        instructions: "message test",
        tools_json: "[]",
        coordination_mode: "hierarchical",
        history_count: 0,
        created_at_ms: System.system_time(:millisecond),
        last_activity_at_ms: System.system_time(:millisecond)
      })

      WriteBuffer.buffer_message(thread_id, message_id, %{
        status: "completed",
        enqueued_at_ms: System.system_time(:millisecond),
        completed_at_ms: System.system_time(:millisecond)
      })

      assert :ok = WriteBuffer.flush()

      messages = EchsStore.list_messages(thread_id, limit: 10)
      assert length(messages) == 1
      assert hd(messages).message_id == message_id
      assert hd(messages).status == "completed"
    end
  end
end
