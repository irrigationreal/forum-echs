defmodule EchsCodex.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias EchsCodex.CircuitBreaker

  setup do
    # CircuitBreaker is started by the application supervisor.
    # Reset state between tests by recording successes to close circuits.
    CircuitBreaker.record_success(:test_codex)
    CircuitBreaker.record_success(:test_claude)
    # Small delay for cast processing
    Process.sleep(10)
    :ok
  end

  describe "check/1" do
    test "returns :ok for unknown/closed circuits" do
      assert :ok = CircuitBreaker.check(:test_codex)
    end

    test "returns :ok after success" do
      CircuitBreaker.record_success(:test_codex)
      Process.sleep(5)
      assert :ok = CircuitBreaker.check(:test_codex)
    end
  end

  describe "record_failure/1" do
    test "does not trip circuit below threshold" do
      for _ <- 1..4 do
        CircuitBreaker.record_failure(:test_codex)
      end

      Process.sleep(10)
      assert :ok = CircuitBreaker.check(:test_codex)
    end

    test "trips circuit at threshold (default 5)" do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:test_codex)
      end

      Process.sleep(10)
      assert {:error, :circuit_open} = CircuitBreaker.check(:test_codex)
    end
  end

  describe "record_success/1" do
    test "resets circuit from open to closed" do
      # Trip the circuit
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:test_codex)
      end

      Process.sleep(10)
      assert {:error, :circuit_open} = CircuitBreaker.check(:test_codex)

      # Record success should not directly close it (circuit is open, not half-open)
      # But we can test the success path by first transitioning to half_open
      CircuitBreaker.record_success(:test_codex)
      Process.sleep(10)
      assert :ok = CircuitBreaker.check(:test_codex)
    end
  end

  describe "state/1" do
    test "returns :closed for unknown circuit" do
      assert :closed = CircuitBreaker.state(:nonexistent)
    end

    test "returns :open after threshold failures" do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:test_claude)
      end

      Process.sleep(10)
      assert :open = CircuitBreaker.state(:test_claude)
    end
  end

  describe "summary/0" do
    test "returns list of known circuits" do
      # Ensure at least one circuit is known
      CircuitBreaker.record_success(:test_codex)
      Process.sleep(10)

      summary = CircuitBreaker.summary()
      assert is_list(summary)

      test_circuit = Enum.find(summary, fn c -> c.circuit == :test_codex end)
      assert test_circuit
      assert test_circuit.state == :closed
      assert test_circuit.consecutive_failures == 0
    end
  end

  describe "independent circuits" do
    test "failures on one circuit don't affect another" do
      for _ <- 1..5 do
        CircuitBreaker.record_failure(:test_codex)
      end

      Process.sleep(10)
      assert {:error, :circuit_open} = CircuitBreaker.check(:test_codex)
      assert :ok = CircuitBreaker.check(:test_claude)
    end
  end
end
