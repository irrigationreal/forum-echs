defmodule EchsCore.HistorySanitizerTest do
  use ExUnit.Case, async: true

  alias EchsCore.HistorySanitizer

  test "repair_output_items/2 returns outputs for missing function_call entries" do
    history = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "hi"}]
      },
      %{
        "type" => "function_call",
        "name" => "read_file",
        "call_id" => "call_123",
        "arguments" => "{\"file_path\":\"README.md\"}"
      }
    ]

    assert [
             %{
               "type" => "function_call_output",
               "call_id" => "call_123",
               "output" => output
             }
           ] = HistorySanitizer.repair_output_items(history, 1234)

    assert output =~ "missing tool output"
    assert output =~ "call_id=call_123"
    assert output =~ "name=read_file"
    assert output =~ "1234ms"
  end

  test "repair_output_items/2 does nothing when outputs are present" do
    history = [
      %{
        "type" => "function_call",
        "name" => "list_dir",
        "call_id" => "call_abc",
        "arguments" => "{}"
      },
      %{"type" => "function_call_output", "call_id" => "call_abc", "output" => "ok"}
    ]

    assert [] = HistorySanitizer.repair_output_items(history, 0)
  end

  test "repair_output_items/2 falls back to id when call_id is missing" do
    history = [
      %{"type" => "function_call", "name" => "grep_files", "id" => "fc_1", "arguments" => "{}"}
    ]

    assert [%{"call_id" => "fc_1"}] = HistorySanitizer.repair_output_items(history, 1)
  end
end
