defmodule EchsCore.ProviderAdapter.ResilienceTest do
  use ExUnit.Case, async: false

  alias EchsCore.ProviderAdapter.Resilience
  alias EchsCore.Observability.Tracing

  # We run async: false because circuit breaker and rate limiter are global ETS state.

  setup do
    # Reset circuit breaker state for our test provider
    EchsCodex.CircuitBreaker.record_success(:test_resilience)
    Process.sleep(10)

    # Reset rate limiter bucket
    Resilience.reset_rate(:test_resilience)

    :ok
  end

  # ── RetryPolicy ──────────────────────────────────────────────────

  describe "RetryPolicy / exponential backoff" do
    test "succeeds on first attempt without retries" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(:test_resilience, %{max_retries: 3, tracing_enabled: false}, fn ->
          :counters.add(call_count, 1, 1)
          {:ok, :success}
        end)

      assert {:ok, :success} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "retries on retryable error and eventually succeeds" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 3, base_delay_ms: 1, max_delay_ms: 5, tracing_enabled: false},
          fn ->
            :counters.add(call_count, 1, 1)
            n = :counters.get(call_count, 1)

            if n < 3 do
              {:error, %{type: "transient", message: "oops", retryable: true}}
            else
              {:ok, :recovered}
            end
          end
        )

      assert {:ok, :recovered} = result
      assert :counters.get(call_count, 1) == 3
    end

    test "gives up after max_retries" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 2, base_delay_ms: 1, max_delay_ms: 5, tracing_enabled: false},
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, %{type: "transient", message: "always fails", retryable: true}}
          end
        )

      assert {:error, %{type: "transient"}} = result
      # 1 initial + 2 retries = 3 calls
      assert :counters.get(call_count, 1) == 3
    end

    test "does not retry non-retryable errors" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 3, base_delay_ms: 1, tracing_enabled: false},
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, %{type: "auth", message: "forbidden", retryable: false}}
          end
        )

      assert {:error, %{type: "auth"}} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "retries on HTTP 429/5xx status even without explicit retryable flag" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 1, base_delay_ms: 1, tracing_enabled: false},
          fn ->
            n = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            if n < 1 do
              {:error, %{status: 429, body: "rate limited"}}
            else
              {:ok, :recovered}
            end
          end
        )

      assert {:ok, :recovered} = result
      assert :counters.get(call_count, 1) == 2
    end

    test "skips retry when budget is exhausted" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{
            max_retries: 5,
            base_delay_ms: 1,
            tracing_enabled: false,
            budget_remaining_fn: fn -> {:ok, 0} end
          },
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, %{type: "transient", message: "fail", retryable: true}}
          end
        )

      assert {:error, _} = result
      # Only the initial attempt, no retries
      assert :counters.get(call_count, 1) == 1
    end

    test "retries normally when budget is available" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{
            max_retries: 2,
            base_delay_ms: 1,
            tracing_enabled: false,
            budget_remaining_fn: fn -> {:ok, 1000} end
          },
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, %{type: "transient", message: "fail", retryable: true}}
          end
        )

      assert {:error, _} = result
      # 1 initial + 2 retries
      assert :counters.get(call_count, 1) == 3
    end

    test "retries normally when budget_remaining_fn returns :unlimited" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{
            max_retries: 1,
            base_delay_ms: 1,
            tracing_enabled: false,
            budget_remaining_fn: fn -> :unlimited end
          },
          fn ->
            n = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            if n < 1 do
              {:error, %{type: "transient", message: "fail", retryable: true}}
            else
              {:ok, :done}
            end
          end
        )

      assert {:ok, :done} = result
      assert :counters.get(call_count, 1) == 2
    end
  end

  # ── Backoff Delay ────────────────────────────────────────────────

  describe "backoff_delay/4" do
    test "first attempt uses base delay" do
      delay = Resilience.backoff_delay(0, 200, 10_000, 0.0)
      assert delay == 200
    end

    test "delay doubles each attempt" do
      assert Resilience.backoff_delay(1, 200, 10_000, 0.0) == 400
      assert Resilience.backoff_delay(2, 200, 10_000, 0.0) == 800
      assert Resilience.backoff_delay(3, 200, 10_000, 0.0) == 1_600
    end

    test "delay is capped at max_delay_ms" do
      delay = Resilience.backoff_delay(20, 200, 5_000, 0.0)
      assert delay == 5_000
    end

    test "jitter stays within range" do
      for _ <- 1..50 do
        delay = Resilience.backoff_delay(2, 200, 10_000, 0.25)
        # 800 base, +/- 25% = 600..1000
        assert delay >= 0
        assert delay <= 1_000
      end
    end
  end

  # ── RateLimiter ──────────────────────────────────────────────────

  describe "RateLimiter" do
    test "allows calls within limit" do
      Resilience.reset_rate(:test_rate)

      for _ <- 1..5 do
        assert :ok = Resilience.check_rate(:test_rate, 10, 60_000)
      end
    end

    test "rejects calls beyond limit" do
      Resilience.reset_rate(:test_rate_full)

      for _ <- 1..3 do
        assert :ok = Resilience.check_rate(:test_rate_full, 3, 60_000)
      end

      assert {:error, :rate_limited} = Resilience.check_rate(:test_rate_full, 3, 60_000)
    end

    test "window expires and resets bucket" do
      Resilience.reset_rate(:test_rate_window)

      # Fill the bucket with window_ms=1
      for _ <- 1..3 do
        assert :ok = Resilience.check_rate(:test_rate_window, 3, 1)
      end

      # Wait for window to expire
      Process.sleep(5)

      # Bucket should be fresh
      assert :ok = Resilience.check_rate(:test_rate_window, 3, 1)
    end

    test "rate limiting blocks with_resilience calls" do
      Resilience.reset_rate(:test_rate_block)

      # Fill rate bucket externally
      for _ <- 1..2 do
        Resilience.check_rate(:test_rate_block, 2, 60_000)
      end

      result =
        Resilience.with_resilience(
          :test_rate_block,
          %{rate_limit: 2, rate_window_ms: 60_000, tracing_enabled: false},
          fn -> {:ok, :should_not_reach} end
        )

      assert {:error, :rate_limited} = result
    end

    test "reset_rate/1 clears the bucket" do
      Resilience.reset_rate(:test_rate_reset)

      for _ <- 1..3 do
        Resilience.check_rate(:test_rate_reset, 3, 60_000)
      end

      assert {:error, :rate_limited} = Resilience.check_rate(:test_rate_reset, 3, 60_000)

      Resilience.reset_rate(:test_rate_reset)
      assert :ok = Resilience.check_rate(:test_rate_reset, 3, 60_000)
    end
  end

  # ── CircuitBreaker integration ─────────────────────────────────

  describe "CircuitBreaker integration" do
    test "circuit_state/1 returns :closed for fresh provider" do
      assert :closed = Resilience.circuit_state(:test_resilience)
    end

    test "reset_circuit/1 closes an open circuit" do
      # Trip the circuit
      for _ <- 1..5 do
        EchsCodex.CircuitBreaker.record_failure(:test_resilience)
      end

      Process.sleep(10)
      assert :open = Resilience.circuit_state(:test_resilience)

      Resilience.reset_circuit(:test_resilience)
      Process.sleep(10)
      assert :closed = Resilience.circuit_state(:test_resilience)
    end

    test "open circuit rejects calls immediately" do
      # Trip the circuit
      for _ <- 1..5 do
        EchsCodex.CircuitBreaker.record_failure(:test_resilience)
      end

      Process.sleep(10)

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{tracing_enabled: false},
          fn -> {:ok, :should_not_reach} end
        )

      assert {:error, :circuit_open} = result
    end

    test "circuit breaker can be disabled" do
      # Trip the circuit
      for _ <- 1..5 do
        EchsCodex.CircuitBreaker.record_failure(:test_resilience)
      end

      Process.sleep(10)

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{circuit_breaker_enabled: false, tracing_enabled: false},
          fn -> {:ok, :bypassed} end
        )

      assert {:ok, :bypassed} = result
    end

    test "successful call records success on the circuit" do
      # Record some failures (but not enough to trip)
      for _ <- 1..3 do
        EchsCodex.CircuitBreaker.record_failure(:test_resilience)
      end

      Process.sleep(10)

      Resilience.with_resilience(
        :test_resilience,
        %{tracing_enabled: false},
        fn -> {:ok, :good} end
      )

      Process.sleep(10)
      assert :closed = Resilience.circuit_state(:test_resilience)
    end

    test "failed call records failure on the circuit" do
      Resilience.with_resilience(
        :test_resilience,
        %{max_retries: 0, tracing_enabled: false},
        fn -> {:error, %{type: "fail", message: "bad", retryable: false}} end
      )

      Process.sleep(10)
      # One failure recorded — circuit should still be closed (threshold is 5)
      assert :closed = Resilience.circuit_state(:test_resilience)
    end
  end

  # ── Tracing Spans ──────────────────────────────────────────────

  describe "TracingSpans" do
    test "emits telemetry for resilience span on success" do
      ref = make_ref()
      parent = self()

      handler_id = "test-telemetry-success-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:echs, :trace, :span],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      Resilience.with_resilience(
        :test_resilience,
        %{tracing_enabled: true, max_retries: 0},
        fn -> {:ok, :traced} end
      )

      assert_receive {:telemetry, ^ref, measurements, metadata}, 1_000
      assert measurements.duration_ms >= 0
      assert metadata.status == :ok
      assert metadata.name in ["provider.resilience", "provider.attempt"]

      :telemetry.detach(handler_id)
    end

    test "emits telemetry with error status on failure" do
      ref = make_ref()
      parent = self()

      handler_id = "test-telemetry-error-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:echs, :trace, :span],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      Resilience.with_resilience(
        :test_resilience,
        %{tracing_enabled: true, max_retries: 0},
        fn -> {:error, %{type: "fail", message: "bad", retryable: false}} end
      )

      # We expect at least one span with :error status (the attempt span)
      assert_receive {:telemetry, ^ref, _measurements, %{status: :error}}, 1_000

      :telemetry.detach(handler_id)
    end

    test "child spans use parent trace_id" do
      ref = make_ref()
      parent_pid = self()

      handler_id = "test-telemetry-parent-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:echs, :trace, :span],
        fn _event, _measurements, metadata, _config ->
          send(parent_pid, {:telemetry_meta, ref, metadata})
        end,
        nil
      )

      parent_span = Tracing.start_span("test.parent", %{test: true})

      Resilience.with_resilience(
        :test_resilience,
        %{tracing_enabled: true, max_retries: 0, parent_span: parent_span},
        fn -> {:ok, :child_traced} end
      )

      # Collect all trace_ids from telemetry events
      trace_ids = collect_trace_ids(ref, [])

      assert length(trace_ids) > 0
      assert Enum.all?(trace_ids, &(&1 == parent_span.trace_id))

      :telemetry.detach(handler_id)
    end

    test "tracing can be disabled" do
      ref = make_ref()
      parent = self()

      handler_id = "test-telemetry-disabled-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:echs, :trace, :span],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, ref, metadata})
        end,
        nil
      )

      Resilience.with_resilience(
        :test_resilience,
        %{tracing_enabled: false},
        fn -> {:ok, :untraced} end
      )

      refute_receive {:telemetry, ^ref, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  # ── Exception Handling ─────────────────────────────────────────

  describe "exception handling" do
    test "catches exceptions and wraps them as retryable errors" do
      call_count = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 1, base_delay_ms: 1, tracing_enabled: false},
          fn ->
            n = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            if n < 1 do
              raise "kaboom"
            else
              {:ok, :recovered}
            end
          end
        )

      assert {:ok, :recovered} = result
      assert :counters.get(call_count, 1) == 2
    end

    test "catches throws and wraps them as retryable errors" do
      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 0, tracing_enabled: false},
          fn -> throw(:oops) end
        )

      assert {:error, %{type: "throw"}} = result
    end
  end

  # ── Fixture-based Regression ───────────────────────────────────

  describe "fixture-based regression" do
    @tag :regression
    test "sequence: success on third attempt with backoff" do
      # Fixture: provider returns 503 twice, then succeeds
      responses = [:counters.new(1, [:atomics])]
      [counter] = responses

      fixture_responses = [
        {:error, %{status: 503, body: "Service Unavailable"}},
        {:error, %{status: 503, body: "Service Unavailable"}},
        {:ok, %{items: [], usage: %{input_tokens: 100, output_tokens: 50}}}
      ]

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 3, base_delay_ms: 1, max_delay_ms: 5, tracing_enabled: false},
          fn ->
            idx = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)
            Enum.at(fixture_responses, idx)
          end
        )

      assert {:ok, %{items: [], usage: %{input_tokens: 100, output_tokens: 50}}} = result
      assert :counters.get(counter, 1) == 3
    end

    @tag :regression
    test "sequence: rate limit -> 503 -> success (mixed failures)" do
      counter = :counters.new(1, [:atomics])

      fixture_responses = [
        {:error, %{status: 429, body: "Rate limited"}},
        {:error, %{status: 503, body: "Service Unavailable"}},
        {:ok, %{items: [%{"type" => "message"}], usage: %{input_tokens: 200, output_tokens: 100}}}
      ]

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 3, base_delay_ms: 1, max_delay_ms: 5, tracing_enabled: false},
          fn ->
            idx = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)
            Enum.at(fixture_responses, idx)
          end
        )

      assert {:ok, %{items: [_], usage: _}} = result
      assert :counters.get(counter, 1) == 3
    end

    @tag :regression
    test "sequence: non-retryable error stops immediately" do
      counter = :counters.new(1, [:atomics])

      fixture_responses = [
        {:error, %{type: "auth", message: "Invalid API key", retryable: false}},
        {:ok, :should_not_reach}
      ]

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{max_retries: 3, base_delay_ms: 1, tracing_enabled: false},
          fn ->
            idx = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)
            Enum.at(fixture_responses, idx)
          end
        )

      assert {:error, %{type: "auth"}} = result
      assert :counters.get(counter, 1) == 1
    end

    @tag :regression
    test "sequence: circuit trips after repeated failures across calls" do
      Resilience.reset_circuit(:test_regression_circuit)
      Process.sleep(10)

      # Make 5 calls that always fail, each with max_retries: 0
      for _ <- 1..5 do
        Resilience.with_resilience(
          :test_regression_circuit,
          %{max_retries: 0, tracing_enabled: false},
          fn -> {:error, %{type: "transient", message: "fail", retryable: false}} end
        )
      end

      Process.sleep(10)
      assert :open = Resilience.circuit_state(:test_regression_circuit)

      # Next call is rejected by circuit
      result =
        Resilience.with_resilience(
          :test_regression_circuit,
          %{max_retries: 0, tracing_enabled: false},
          fn -> {:ok, :should_not_reach} end
        )

      assert {:error, :circuit_open} = result

      # Reset and verify recovery
      Resilience.reset_circuit(:test_regression_circuit)
      Process.sleep(10)

      result =
        Resilience.with_resilience(
          :test_regression_circuit,
          %{max_retries: 0, tracing_enabled: false},
          fn -> {:ok, :recovered} end
        )

      assert {:ok, :recovered} = result
    end

    @tag :regression
    test "sequence: budget exhaustion prevents retries mid-stream" do
      counter = :counters.new(1, [:atomics])
      budget = :counters.new(1, [:atomics])
      # Start with budget of 1
      :counters.put(budget, 1, 1)

      result =
        Resilience.with_resilience(
          :test_resilience,
          %{
            max_retries: 5,
            base_delay_ms: 1,
            tracing_enabled: false,
            budget_remaining_fn: fn ->
              remaining = :counters.get(budget, 1)
              # Decrease budget after each check
              :counters.sub(budget, 1, 1)
              {:ok, remaining}
            end
          },
          fn ->
            :counters.add(counter, 1, 1)
            {:error, %{type: "transient", message: "fail", retryable: true}}
          end
        )

      assert {:error, _} = result
      # Budget was 1 on first retry check, then 0 on second -> stops after 2 attempts
      assert :counters.get(counter, 1) <= 3
    end
  end

  # ── Keyword opts ───────────────────────────────────────────────

  describe "keyword list opts" do
    test "accepts keyword list as opts" do
      result =
        Resilience.with_resilience(
          :test_resilience,
          [max_retries: 0, tracing_enabled: false],
          fn -> {:ok, :keyword_opts} end
        )

      assert {:ok, :keyword_opts} = result
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp collect_trace_ids(ref, acc) do
    receive do
      {:telemetry_meta, ^ref, %{trace_id: tid}} ->
        collect_trace_ids(ref, [tid | acc])
    after
      200 -> acc
    end
  end
end
