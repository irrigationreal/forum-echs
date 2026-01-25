defmodule EchsCli do
  @moduledoc """
  Simple CLI for testing ECHS.
  """

  @doc """
  Main entry point. Start an interactive session.
  """
  def main(args \\ []) do
    # Start the applications
    {:ok, _} = Application.ensure_all_started(:echs_core)
    {:ok, _} = Application.ensure_all_started(:echs_codex)

    cwd =
      case args do
        [dir | _] -> Path.expand(dir)
        [] -> File.cwd!()
      end

    IO.puts("ECHS - Elixir Codex Harness Server")
    IO.puts("Working directory: #{cwd}")
    IO.puts("Type 'quit' to exit\n")

    # Create a thread
    {:ok, thread_id} = EchsCore.ThreadWorker.create(cwd: cwd)
    IO.puts("Thread created: #{thread_id}")

    # Spawn event printer with subscription
    parent = self()

    spawn_link(fn ->
      EchsCore.ThreadWorker.subscribe(thread_id)
      send(parent, :event_loop_ready)
      event_loop()
    end)

    # Wait for event loop to be ready
    receive do
      :event_loop_ready -> :ok
    after
      1000 -> IO.puts("Warning: event loop subscription timeout")
    end

    # REPL loop
    repl_loop(thread_id)
  end

  defp repl_loop(thread_id) do
    case IO.gets("> ") do
      :eof ->
        IO.puts("\nGoodbye!")

      input when is_binary(input) ->
        input = String.trim(input)

        cond do
          input in ["quit", "exit"] ->
            IO.puts("Goodbye!")

          input == "" ->
            repl_loop(thread_id)

          true ->
            IO.puts("\n--- Sending message ---")

            case EchsCore.ThreadWorker.send_message(thread_id, input) do
              {:ok, _history} ->
                IO.puts("\n--- Turn complete ---\n")

              {:error, err} ->
                IO.puts("\nError: #{inspect(err)}\n")
            end

            repl_loop(thread_id)
        end
    end
  end

  defp event_loop do
    receive do
      {:turn_started, data} ->
        IO.puts("[Turn started] #{data.thread_id}")

      {:item_started, data} ->
        type = data.item["type"]
        IO.write("[Item: #{type}] ")

      {:turn_delta, data} ->
        IO.write(data.content)

      {:item_completed, data} ->
        item = data.item

        case item["type"] do
          "message" ->
            content = get_in(item, ["content", Access.at(0), "text"]) || ""
            IO.puts("\n[Assistant]: #{content}")

          "function_call" ->
            IO.puts("\n[Tool Call]: #{item["name"]}(#{truncate(item["arguments"], 100)})")

          "local_shell_call" ->
            cmd = get_in(item, ["action", "command"]) || []
            IO.puts("\n[Shell]: #{Enum.join(cmd, " ")}")

          _ ->
            IO.puts("\n[#{item["type"]}]")
        end

      {:tool_completed, data} ->
        IO.puts("[Tool Result]: #{truncate(data.result, 200)}")

      {:turn_completed, _data} ->
        :ok

      {:turn_error, data} ->
        IO.puts("\n[Error]: #{inspect(data.error)}")

      {:subagent_spawned, data} ->
        IO.puts("[Subagent Spawned]: #{data.agent_id} - #{data.task}")

      msg ->
        IO.puts("[Event]: #{inspect(msg)}")
    end

    event_loop()
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp truncate(other, _), do: inspect(other)
end
