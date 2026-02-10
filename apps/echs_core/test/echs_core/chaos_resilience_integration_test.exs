defmodule EchsCore.ChaosResilienceIntegrationTest do
  use ExUnit.Case, async: false

  alias EchsCore.ProviderAdapter.Resilience

  setup do
    Resilience.init_rate_table()
    Resilience.reset_rate(:test_provider)
    :ok
  end

  describe "resilience retries through transient provider errors" do
    test "retries transient 503 errors and succeeds" do
      counter = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_provider,
          %{max_retries: 3, base_delay_ms: 10, max_delay_ms: 50, circuit_breaker_enabled: false, tracing_enabled: false},
          fn ->
            attempt = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if attempt < 2 do
              {:error, %{status: 503, body: "Service Unavailable"}}
            else
              {:ok, %{status: 200}}
            end
          end
        )

      assert {:ok, %{status: 200}} = result
      # 2 failures + 1 success = 3 total attempts
      assert :counters.get(counter, 1) == 3
    end

    test "gives up after max retries are exhausted" do
      counter = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_provider,
          %{max_retries: 2, base_delay_ms: 10, max_delay_ms: 50, circuit_breaker_enabled: false, tracing_enabled: false},
          fn ->
            :counters.add(counter, 1, 1)
            {:error, %{status: 503, body: "Service Unavailable"}}
          end
        )

      assert {:error, %{status: 503}} = result
      # Initial attempt + 2 retries = 3 total attempts
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry non-retryable errors" do
      counter = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_provider,
          %{max_retries: 3, base_delay_ms: 10, max_delay_ms: 50, circuit_breaker_enabled: false, tracing_enabled: false},
          fn ->
            :counters.add(counter, 1, 1)
            {:error, %{status: 401, body: "Unauthorized"}}
          end
        )

      assert {:error, %{status: 401}} = result
      # Only 1 attempt — no retries for 401
      assert :counters.get(counter, 1) == 1
    end

    test "rate limiter rejects when limit exceeded" do
      # Use a very low rate limit
      opts = %{
        max_retries: 0,
        rate_limit: 2,
        rate_window_ms: 60_000,
        circuit_breaker_enabled: false,
        tracing_enabled: false
      }

      Resilience.reset_rate(:rate_test_provider)

      # First two calls succeed
      assert {:ok, :first} =
               Resilience.with_resilience(:rate_test_provider, opts, fn -> {:ok, :first} end)

      assert {:ok, :second} =
               Resilience.with_resilience(:rate_test_provider, opts, fn -> {:ok, :second} end)

      # Third call hits the rate limit
      assert {:error, :rate_limited} =
               Resilience.with_resilience(:rate_test_provider, opts, fn -> {:ok, :third} end)
    end

    test "retries through exception and recovers" do
      counter = :counters.new(1, [:atomics])

      result =
        Resilience.with_resilience(
          :test_provider,
          %{max_retries: 3, base_delay_ms: 10, max_delay_ms: 50, circuit_breaker_enabled: false, tracing_enabled: false},
          fn ->
            attempt = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if attempt < 1 do
              raise "transient connection error"
            else
              {:ok, %{items: [], usage: %{}}}
            end
          end
        )

      assert {:ok, _} = result
      assert :counters.get(counter, 1) == 2
    end
  end
end
