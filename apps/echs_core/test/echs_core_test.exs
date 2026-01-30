defmodule EchsCore.BlackboardTest do
  use ExUnit.Case, async: true

  alias EchsCore.Blackboard

  setup do
    name = {:global, {__MODULE__, make_ref()}}
    {:ok, _pid} = start_supervised({Blackboard, name: name})
    %{blackboard: name}
  end

  test "set/get round trip", %{blackboard: blackboard} do
    assert :ok == Blackboard.set(blackboard, "key", "value")
    assert {:ok, "value"} == Blackboard.get(blackboard, "key")
  end

  test "watchers receive updates", %{blackboard: blackboard} do
    assert :ok == Blackboard.watch(blackboard, "watched", self())
    assert :ok == Blackboard.set(blackboard, "watched", 123)
    assert_receive {:blackboard_update, "watched", 123}
  end

  test "clear removes entries", %{blackboard: blackboard} do
    assert :ok == Blackboard.set(blackboard, "key", "value")
    assert :ok == Blackboard.clear(blackboard)
    assert :not_found == Blackboard.get(blackboard, "key")
  end
end

defmodule EchsCore.ThreadWorkerToolTest do
  use ExUnit.Case, async: false

  alias EchsCore.ThreadWorker

  setup_all do
    Application.ensure_all_started(:echs_core)
    :ok
  end

  test "registers custom tool handler" do
    {:ok, thread_id} = ThreadWorker.create()

    spec = %{
      "type" => "function",
      "name" => "custom_tool",
      "description" => "Custom test tool",
      "parameters" => %{"type" => "object"}
    }

    handler = fn _args, _ctx -> {:ok, "done"} end

    assert :ok == ThreadWorker.add_tool(thread_id, spec, handler)

    state = ThreadWorker.get_state(thread_id)
    assert Enum.any?(state.tools, fn tool -> (tool["name"] || tool[:name]) == "custom_tool" end)
    assert Map.has_key?(state.tool_handlers, "custom_tool")
  end

  test "model switch refreshes core tools while preserving custom tools" do
    {:ok, thread_id} = ThreadWorker.create()

    spec = %{
      "type" => "function",
      "name" => "custom_tool_refresh",
      "description" => "Custom test tool",
      "parameters" => %{"type" => "object"}
    }

    handler = fn _args, _ctx -> {:ok, "done"} end

    assert :ok == ThreadWorker.add_tool(thread_id, spec, handler)
    assert :ok == ThreadWorker.configure(thread_id, %{"model" => "opus"})

    state = ThreadWorker.get_state(thread_id)
    tool_names = Enum.map(state.tools, fn tool -> tool["name"] || tool[:name] end)

    assert "exec_command" in tool_names
    assert "write_stdin" in tool_names
    assert "custom_tool_refresh" in tool_names
  end
end
