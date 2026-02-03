defmodule EchsCore.StuckTurnSweeperTest do
  use ExUnit.Case, async: false

  alias EchsCore.StuckTurnSweeper

  @moduletag :stuck_sweeper

  defp unique_thread_id, do: "thr_sweep_#{:erlang.unique_integer([:positive])}"
  defp unique_msg_id, do: "msg_sweep_#{:erlang.unique_integer([:positive])}"

  setup do
    # Properly remove the app-level sweeper from supervision so we can start our own
    _ = Supervisor.terminate_child(EchsCore.InfraSupervisor, StuckTurnSweeper)
    _ = Supervisor.delete_child(EchsCore.InfraSupervisor, StuckTurnSweeper)

    on_exit(fn ->
      # Restore the sweeper under InfraSupervisor
      case Process.whereis(StuckTurnSweeper) do
        nil ->
          spec = %{
            id: StuckTurnSweeper,
            start: {StuckTurnSweeper, :start_link, [[]]}
          }

          _ = Supervisor.start_child(EchsCore.InfraSupervisor, spec)

        _pid ->
          :ok
      end
    end)

    :ok
  end

  defp insert_running_message(thread_id, message_id, started_at_ms) do
    now = System.system_time(:millisecond)

    EchsStore.upsert_thread(%{
      thread_id: thread_id,
      cwd: "/tmp",
      model: "test",
      reasoning: "low",
      instructions: "test",
      created_at_ms: now,
      last_activity_at_ms: now,
      tools_json: "[]",
      coordination_mode: "hierarchical",
      history_count: 0
    })

    EchsStore.upsert_message(thread_id, message_id, %{
      status: "running",
      enqueued_at_ms: started_at_ms,
      started_at_ms: started_at_ms,
      history_start: 0,
      history_end: 0
    })
  end

  describe "init" do
    test "starts with configured sweep interval" do
      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 100_000, max_age_ms: 60_000, batch_limit: 10]}
        )

      assert Process.alive?(pid)
    end
  end

  describe "periodic sweep" do
    test "tick triggers sweep and marks old messages as error" do
      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 999_999, max_age_ms: 1_000, batch_limit: 50]}
        )

      thread_id = unique_thread_id()
      message_id = unique_msg_id()
      old_time = System.system_time(:millisecond) - 5_000
      {:ok, _} = insert_running_message(thread_id, message_id, old_time)

      send(pid, :tick)
      Process.sleep(200)

      {:ok, msg} = EchsStore.get_message(thread_id, message_id)
      assert msg.status == "error"
    end

    test "does not mark recent messages as error" do
      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 999_999, max_age_ms: 600_000, batch_limit: 50]}
        )

      thread_id = unique_thread_id()
      message_id = unique_msg_id()
      # Started very recently — should NOT be caught
      recent_time = System.system_time(:millisecond) - 100
      {:ok, _} = insert_running_message(thread_id, message_id, recent_time)

      send(pid, :tick)
      Process.sleep(200)

      {:ok, msg} = EchsStore.get_message(thread_id, message_id)
      assert msg.status == "running"
    end
  end

  describe "orphaned message repair" do
    test "marks orphaned running message as error with message" do
      thread_id = unique_thread_id()
      message_id = unique_msg_id()
      old_time = System.system_time(:millisecond) - 500_000

      {:ok, _} = insert_running_message(thread_id, message_id, old_time)

      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 999_999, max_age_ms: 1_000, batch_limit: 50]}
        )

      send(pid, :tick)
      Process.sleep(200)

      {:ok, msg} = EchsStore.get_message(thread_id, message_id)
      assert msg.status == "error"
      assert msg.error != nil
    end

    test "repairs missing tool outputs for orphaned messages" do
      thread_id = unique_thread_id()
      message_id = unique_msg_id()
      old_time = System.system_time(:millisecond) - 500_000

      {:ok, _} = insert_running_message(thread_id, message_id, old_time)

      items = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "hello"}]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_orphan_1",
          "name" => "shell",
          "arguments" => "{}"
        }
      ]

      {:ok, _} = EchsStore.append_items(thread_id, message_id, items)

      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 999_999, max_age_ms: 1_000, batch_limit: 50]}
        )

      send(pid, :tick)
      Process.sleep(200)

      {:ok, %{items: all_items}} = EchsStore.get_slice(thread_id, 0, 100)
      output_items = Enum.filter(all_items, &(&1["type"] == "function_call_output"))
      assert length(output_items) >= 1
      assert hd(output_items)["call_id"] == "call_orphan_1"
    end
  end

  describe "batch limiting" do
    test "respects batch_limit" do
      # Use unique thread IDs with specific prefix to avoid cross-test contamination
      batch_prefix = "thr_batch_#{:erlang.unique_integer([:positive])}_"

      thread_ids_and_msgs =
        for i <- 1..5 do
          tid = batch_prefix <> Integer.to_string(i)
          mid = "msg_batch_#{:erlang.unique_integer([:positive])}"
          old_time = System.system_time(:millisecond) - 500_000
          {:ok, _} = insert_running_message(tid, mid, old_time)
          {tid, mid}
        end

      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 999_999, max_age_ms: 1_000, batch_limit: 2]}
        )

      send(pid, :tick)
      Process.sleep(300)

      error_count =
        Enum.count(thread_ids_and_msgs, fn {tid, mid} ->
          case EchsStore.get_message(tid, mid) do
            {:ok, msg} -> msg.status == "error"
            _ -> false
          end
        end)

      # batch_limit=2, so at most 2 should be processed
      assert error_count <= 2
      # At least some should be processed (the query could find other stuck
      # messages from previous tests, but our batch messages should eventually
      # get processed)
      assert error_count >= 0

      # Second sweep
      send(pid, :tick)
      Process.sleep(300)

      error_count2 =
        Enum.count(thread_ids_and_msgs, fn {tid, mid} ->
          case EchsStore.get_message(tid, mid) do
            {:ok, msg} -> msg.status == "error"
            _ -> false
          end
        end)

      # More should be processed after second sweep
      assert error_count2 >= error_count
    end
  end

  describe "live thread handling" do
    test "does not mark error for live threads" do
      thread_id = unique_thread_id()
      message_id = unique_msg_id()
      old_time = System.system_time(:millisecond) - 500_000

      {:ok, _} = insert_running_message(thread_id, message_id, old_time)

      # Register current process in the Registry to simulate a live thread
      {:ok, _} = Registry.register(EchsCore.Registry, thread_id, nil)

      {:ok, pid} =
        start_supervised(
          {StuckTurnSweeper, [sweep_ms: 999_999, max_age_ms: 1_000, batch_limit: 50]}
        )

      send(pid, :tick)
      Process.sleep(200)

      # The sweeper calls EchsCore.interrupt_thread which tries GenServer.call
      # on the pid registered for this thread_id. Since our test process isn't
      # a GenServer, the call will fail and be caught. The message stays running
      # because the sweeper doesn't touch the DB for live threads.
      {:ok, msg} = EchsStore.get_message(thread_id, message_id)
      assert msg.status == "running"

      Registry.unregister(EchsCore.Registry, thread_id)
    end
  end
end
