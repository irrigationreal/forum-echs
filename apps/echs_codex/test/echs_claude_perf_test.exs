defmodule EchsClaudePerfTest do
  use ExUnit.Case, async: true

  test "reasoning normalization scales linearly under stream load" do
    small_events =
      for _ <- 1..200 do
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "x"}
        }
      end ++ [%{"type" => "message_stop"}]

    large_events =
      for _ <- 1..2000 do
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "x"}
        }
      end ++ [%{"type" => "message_stop"}]

    _ = EchsClaude.test_normalize_events(small_events, reasoning: "medium")

    small_ms =
      measure_ms(fn ->
        _ = EchsClaude.test_normalize_events(small_events, reasoning: "medium")
      end)

    large_ms =
      measure_ms(fn ->
        _ = EchsClaude.test_normalize_events(large_events, reasoning: "medium")
      end)

    baseline = max(small_ms, 1)

    assert large_ms < baseline * 25 + 100
    assert large_ms < 2000
  end

  defp measure_ms(fun) do
    started_at = System.monotonic_time(:millisecond)
    fun.()
    System.monotonic_time(:millisecond) - started_at
  end
end
