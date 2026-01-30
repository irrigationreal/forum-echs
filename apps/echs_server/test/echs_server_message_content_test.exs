defmodule EchsServer.MessageContentTest do
  use ExUnit.Case, async: true

  alias EchsServer.MessageContent

  test "passes through valid content parts" do
    assert {:ok, [%{"type" => "input_text", "text" => "hi"}]} =
             MessageContent.normalize([%{"type" => "input_text", "text" => "hi"}])
  end

  test "converts bare strings into input_text parts" do
    assert {:ok, [%{"type" => "input_text", "text" => "hello"}]} =
             MessageContent.normalize(["hello"])
  end

  test "unwraps a nested user message item into input_text" do
    assert {:ok, [%{"type" => "input_text", "text" => "Say: OK"}]} =
             MessageContent.normalize([
               %{"type" => "message", "role" => "user", "content" => "Say: OK"}
             ])
  end

  test "unwraps a chat-completions-style user message item (no type) into input_text" do
    assert {:ok, [%{"type" => "input_text", "text" => "Say: OK"}]} =
             MessageContent.normalize([
               %{"role" => "user", "content" => "Say: OK"}
             ])
  end

  test "unwraps a nested user message item with content parts" do
    assert {:ok, [%{"type" => "input_text", "text" => "hello"}]} =
             MessageContent.normalize([
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "hello"}]
               }
             ])
  end

  test "unwraps a chat-completions-style user message item with content parts" do
    assert {:ok, [%{"type" => "input_text", "text" => "hello"}]} =
             MessageContent.normalize([
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "hello"}]
               }
             ])
  end

  test "rejects non-user roles in message items" do
    assert {:error, reason} =
             MessageContent.normalize([
               %{"type" => "message", "role" => "assistant", "content" => "nope"}
             ])

    assert is_map(reason)
    assert reason[:reason] == "only user message items are allowed in content lists"
  end

  test "rejects non-user roles in chat-completions-style message items" do
    assert {:error, reason} =
             MessageContent.normalize([
               %{"role" => "assistant", "content" => "nope"}
             ])

    assert is_map(reason)
    assert reason[:reason] == "only user message items are allowed in content lists"
  end

  test "rejects tool-call types in content items" do
    assert {:error, reason} = MessageContent.normalize([%{"type" => "function_call"}])
    assert is_map(reason)
    assert reason[:type] == "function_call"
  end
end
