defmodule EchsCore.TurnLimiterTest do
  use ExUnit.Case, async: false

  alias EchsCore.TurnLimiter

  # Start a dedicated TurnLimiter per test to avoid interfering with the
  # application-level instance. We stop it in on_exit.
  defp start_limiter(limit) do
    # Stop the app-level limiter so we can start our own on the same name
    name = :"test_limiter_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(TurnLimiter, [limit: limit], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  describe "unlimited mode" do
    test "acquire always returns {:ok, ref} immediately" do
      # The app-level TurnLimiter defaults to :infinity
      assert {:ok, ref} = TurnLimiter.acquire()
      assert is_reference(ref)
      TurnLimiter.release(ref)
    end

    test "release and cancel are no-ops in unlimited mode" do
      {:ok, ref} = TurnLimiter.acquire()
      assert :ok = TurnLimiter.release(ref)
      assert :ok = TurnLimiter.cancel(ref)
    end
  end

  describe "limited mode" do
    test "acquire grants slot when under limit" do
      {pid, _name} = start_limiter(2)

      assert {:ok, _ref} = GenServer.call(pid, {:acquire, self()})
      assert {:ok, _ref} = GenServer.call(pid, {:acquire, self()})
    end

    test "acquire queues when at limit" do
      {pid, _name} = start_limiter(1)

      # First acquire succeeds
      assert {:ok, _ref1} = GenServer.call(pid, {:acquire, self()})

      # Second acquire is queued
      assert {:wait, _ref2} = GenServer.call(pid, {:acquire, self()})
    end

    test "release grants next queued waiter" do
      {pid, _name} = start_limiter(1)

      # Acquire one slot
      assert {:ok, ref1} = GenServer.call(pid, {:acquire, self()})

      # Queue a second request
      assert {:wait, ref2} = GenServer.call(pid, {:acquire, self()})

      # Release first slot — should grant to queued waiter
      GenServer.cast(pid, {:release, ref1})

      # We should receive the grant message
      assert_receive {:turn_slot_granted, ^ref2}, 1000
    end

    test "cancel removes from queue" do
      {pid, _name} = start_limiter(1)

      # Fill the slot
      assert {:ok, _ref1} = GenServer.call(pid, {:acquire, self()})

      # Queue a second
      assert {:wait, ref2} = GenServer.call(pid, {:acquire, self()})

      # Cancel the queued request
      GenServer.cast(pid, {:cancel, ref2})

      # Give a moment for cast to process
      :sys.get_state(pid)

      # Queue should be empty now — verify by getting state
      state = :sys.get_state(pid)
      assert :queue.is_empty(state.queue)
    end

    test "crash releases slot (monitoring)" do
      {pid, _name} = start_limiter(1)

      # Spawn a process that acquires a slot then crashes
      holder =
        spawn(fn ->
          {:ok, _ref} = GenServer.call(pid, {:acquire, self()})
          # Wait to be killed
          receive do
            :crash -> exit(:boom)
          end
        end)

      # Give holder time to acquire
      Process.sleep(50)

      # Verify slot is in use
      state = :sys.get_state(pid)
      assert MapSet.size(state.in_use) == 1

      # Queue ourselves
      assert {:wait, our_ref} = GenServer.call(pid, {:acquire, self()})

      # Kill the holder
      send(holder, :crash)
      Process.sleep(50)

      # We should receive the grant since the crashed holder's slot was released
      assert_receive {:turn_slot_granted, ^our_ref}, 1000

      # Verify monitors cleaned up
      state = :sys.get_state(pid)
      assert MapSet.size(state.in_use) == 1
      assert map_size(state.monitors) == 1
    end

    test "concurrent acquire and release" do
      {pid, _name} = start_limiter(3)

      # Spawn 10 processes that each acquire, hold briefly, then release
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            case GenServer.call(pid, {:acquire, self()}) do
              {:ok, ref} ->
                Process.sleep(Enum.random(10..30))
                GenServer.cast(pid, {:release, ref})
                :acquired

              {:wait, ref} ->
                receive do
                  {:turn_slot_granted, ^ref} ->
                    Process.sleep(Enum.random(10..30))
                    GenServer.cast(pid, {:release, ref})
                    :waited_then_acquired
                after
                  2000 -> :timeout
                end
            end
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should have completed successfully
      assert Enum.all?(results, &(&1 in [:acquired, :waited_then_acquired]))

      # All slots should be released
      state = :sys.get_state(pid)
      assert MapSet.size(state.in_use) == 0
      assert :queue.is_empty(state.queue)
      assert map_size(state.monitors) == 0
    end

    test "dead process in queue is skipped during grant" do
      {pid, _name} = start_limiter(1)

      # Fill the slot
      assert {:ok, ref1} = GenServer.call(pid, {:acquire, self()})

      # Spawn a process that queues then dies
      _dead_waiter =
        spawn(fn ->
          {:wait, _ref} = GenServer.call(pid, {:acquire, self()})
          # Just exit immediately
        end)

      # Give it time to queue and die
      Process.sleep(50)

      # Queue ourselves
      assert {:wait, our_ref} = GenServer.call(pid, {:acquire, self()})

      # Release first slot — dead waiter should be skipped, we get the grant
      GenServer.cast(pid, {:release, ref1})

      assert_receive {:turn_slot_granted, ^our_ref}, 1000
    end
  end
end
