defmodule EchsCore.StreamRunnerTest do
  use ExUnit.Case, async: true

  alias EchsCore.ThreadWorker.StreamRunner

  describe "assistant_message?/1" do
    test "recognizes assistant messages" do
      assert StreamRunner.assistant_message?(%{"type" => "message", "role" => "assistant"})
    end

    test "rejects non-assistant messages" do
      refute StreamRunner.assistant_message?(%{"type" => "message", "role" => "user"})
      refute StreamRunner.assistant_message?(%{"type" => "function_call"})
      refute StreamRunner.assistant_message?(nil)
    end
  end

  describe "extract_message_text/1" do
    test "extracts text from content list" do
      item = %{
        "content" => [
          %{"type" => "text", "text" => "hello"},
          %{"type" => "text", "text" => "world"}
        ]
      }

      assert StreamRunner.extract_message_text(item) == "hello world"
    end

    test "extracts text from string content" do
      assert StreamRunner.extract_message_text(%{"content" => "plain text"}) == "plain text"
    end

    test "returns empty for nil" do
      assert StreamRunner.extract_message_text(nil) == ""
    end

    test "returns empty for missing content" do
      assert StreamRunner.extract_message_text(%{}) == ""
    end
  end

  describe "extract_text_content/1" do
    test "handles binary content" do
      assert StreamRunner.extract_text_content("hello") == "hello"
    end

    test "handles list of text blocks" do
      content = [
        %{"type" => "text", "text" => "a"},
        %{"type" => "text", "text" => "b"}
      ]

      assert StreamRunner.extract_text_content(content) == "a b"
    end

    test "handles nested content" do
      assert StreamRunner.extract_text_content(%{"content" => "nested"}) == "nested"
    end

    test "returns empty for unknown types" do
      assert StreamRunner.extract_text_content(42) == ""
      assert StreamRunner.extract_text_content(%{"type" => "image"}) == ""
    end
  end

  describe "reasoning_summary_text/1" do
    test "extracts from delta wrapper" do
      assert StreamRunner.reasoning_summary_text(%{"delta" => %{"text" => "thinking"}}) ==
               "thinking"
    end

    test "extracts from summary wrapper" do
      assert StreamRunner.reasoning_summary_text(%{"summary" => "reasoning"}) == "reasoning"
    end

    test "extracts direct text" do
      assert StreamRunner.reasoning_summary_text(%{"text" => "direct"}) == "direct"
    end

    test "handles string input" do
      assert StreamRunner.reasoning_summary_text("plain") == "plain"
    end

    test "handles list of summaries" do
      assert StreamRunner.reasoning_summary_text([%{"text" => "a"}, %{"text" => "b"}]) == "ab"
    end

    test "returns empty for nil" do
      assert StreamRunner.reasoning_summary_text(nil) == ""
    end
  end

  describe "normalize_assistant_items/2" do
    test "converts intermediate assistant messages to reasoning items" do
      items = [
        %{"type" => "message", "role" => "assistant", "content" => "thought 1"},
        %{"type" => "function_call", "name" => "test"},
        %{"type" => "message", "role" => "assistant", "content" => "thought 2"}
      ]

      {normalized, events} = StreamRunner.normalize_assistant_items(items, true)

      # First assistant message converted to reasoning, last kept as message
      assert length(normalized) == 3
      assert Enum.at(normalized, 0)["type"] == "reasoning"
      assert Enum.at(normalized, 1)["type"] == "function_call"
      assert Enum.at(normalized, 2)["type"] == "message"

      assert length(events) == 2
      assert {:reasoning, _} = Enum.at(events, 0)
      assert {:assistant, _} = Enum.at(events, 1)
    end

    test "converts all assistant messages when keep_last is false" do
      items = [
        %{"type" => "message", "role" => "assistant", "content" => "only one"}
      ]

      {normalized, events} = StreamRunner.normalize_assistant_items(items, false)

      assert length(normalized) == 1
      assert Enum.at(normalized, 0)["type"] == "reasoning"
      assert [{:reasoning, _}] = events
    end

    test "passes through non-list items" do
      assert {nil, []} = StreamRunner.normalize_assistant_items(nil, true)
    end
  end

  describe "maybe_send_usage/2" do
    test "sends usage for response.completed events" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 50
          }
        }
      }

      StreamRunner.maybe_send_usage(self(), event)
      assert_receive {:usage_update, %{"input_tokens" => 100, "output_tokens" => 50}}
    end

    test "sends usage for message_start events" do
      event = %{
        "type" => "message_start",
        "usage" => %{"input_tokens" => 200, "output_tokens" => 0}
      }

      StreamRunner.maybe_send_usage(self(), event)
      assert_receive {:usage_update, %{"input_tokens" => 200, "output_tokens" => 0}}
    end

    test "ignores events without usage" do
      StreamRunner.maybe_send_usage(self(), %{"type" => "response.output_text.delta"})
      refute_receive {:usage_update, _}
    end

    test "ignores events with no recognized type" do
      StreamRunner.maybe_send_usage(self(), %{"type" => "unknown"})
      refute_receive {:usage_update, _}
    end
  end
end
