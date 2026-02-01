defmodule EchsClaudePerfTest do
  use ExUnit.Case, async: true

  test "reasoning normalization scales linearly under stream load" do
    small_n = 200
    large_n = small_n * 10

    small_events = thinking_delta_events(small_n)
    large_events = thinking_delta_events(large_n)

    small_call_us =
      per_call_us(
        fn ->
          _ = EchsClaude.test_normalize_events(small_events, reasoning: "medium")
        end,
        repeats: 40
      )

    large_call_us =
      per_call_us(
        fn ->
          _ = EchsClaude.test_normalize_events(large_events, reasoning: "medium")
        end,
        repeats: 6
      )

    ratio = large_call_us / max(small_call_us, 1.0)

    # Ratio-based guard: for a 10x input, runtime should be roughly linear.
    # We keep a generous ceiling to avoid flakiness on noisy CI machines.
    assert ratio < 40
  end

  defp thinking_delta_events(n) when is_integer(n) and n > 0 do
    for _ <- 1..n do
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "x"}
      }
    end ++ [%{"type" => "message_stop"}]
  end

  defp per_call_us(fun, opts) when is_function(fun, 0) do
    repeats = Keyword.get(opts, :repeats, 10)
    samples = Keyword.get(opts, :samples, 5)

    _ = fun.()

    per_sample_us =
      for _ <- 1..samples do
        {us, _} =
          :timer.tc(fn ->
            for _ <- 1..repeats, do: fun.()
          end)

        us / repeats
      end

    median(per_sample_us)
  end

  defp median(values) when is_list(values) and values != [] do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
