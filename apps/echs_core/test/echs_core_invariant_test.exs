defmodule EchsCore.Rune.InvariantTest do
  use ExUnit.Case, async: true

  alias EchsCore.Rune.Invariant

  describe "inv_ok?/3" do
    test "returns true when condition holds" do
      assert Invariant.inv_ok?("INV-TEST", true) == true
    end

    test "returns false and raises in lab mode when condition fails" do
      assert_raise RuntimeError, ~r/INV-TEST-FAIL/, fn ->
        Invariant.inv_ok?("INV-TEST-FAIL", false, message: "test violation")
      end
    end

    test "returns false with context" do
      assert_raise RuntimeError, ~r/INV-CTX/, fn ->
        Invariant.inv_ok?("INV-CTX", false,
          message: "context test",
          context: %{call_id: "call_1"}
        )
      end
    end

    test "warn severity does not raise in lab mode" do
      # Warn violations don't raise even in lab mode
      result = Invariant.inv_ok?("INV-WARN-TEST", false,
        severity: :warn,
        message: "just a warning"
      )
      assert result == false
    end
  end

  describe "inv_fail/3" do
    test "raises in lab mode for error severity" do
      assert_raise RuntimeError, ~r/INV-EXPLICIT/, fn ->
        Invariant.inv_fail("INV-EXPLICIT", "explicit failure")
      end
    end

    test "does not raise for warn severity" do
      assert :ok = Invariant.inv_fail("INV-WARN-EXPLICIT", "just a warning", severity: :warn)
    end
  end

  describe "mode/0" do
    test "returns :lab in test environment" do
      assert Invariant.mode() == :lab
    end
  end

  describe "rate limiting" do
    test "second violation within window is suppressed" do
      # Clear any previous rate limit state
      Process.delete({:inv_rate, "INV-RATE-TEST"})

      # First call should raise (not rate limited)
      assert_raise RuntimeError, fn ->
        Invariant.inv_ok?("INV-RATE-TEST", false, message: "first")
      end

      # Second call within the same millisecond window should be rate limited
      # and therefore not raise
      result = Invariant.inv_ok?("INV-RATE-TEST", false, message: "second")
      assert result == false
    end
  end
end
