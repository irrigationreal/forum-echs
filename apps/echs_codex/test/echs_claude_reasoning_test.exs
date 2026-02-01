defmodule EchsClaudeReasoningTest do
  use ExUnit.Case, async: true

  test "normalizes Claude thinking into reasoning deltas + summary" do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "Plan: "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "step1 "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "step2"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_stop"}
    ]

    normalized = EchsClaude.test_normalize_events(events, reasoning: "medium")

    deltas =
      normalized
      |> Enum.filter(fn event -> event["type"] == "response.reasoning_summary.delta" end)
      |> Enum.map(& &1["delta"])

    assert deltas == ["Plan: ", "step1 ", "step2"]

    refute Enum.any?(normalized, fn event ->
             event["type"] == "response.reasoning_summary"
           end)
  end

  test "reasoning none suppresses Claude thinking deltas" do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "Hidden"}
      },
      %{"type" => "message_stop"}
    ]

    normalized = EchsClaude.test_normalize_events(events, reasoning: "none")

    refute Enum.any?(normalized, fn event ->
             event["type"] in ["response.reasoning_summary.delta", "response.reasoning_summary"]
           end)
  end
end
