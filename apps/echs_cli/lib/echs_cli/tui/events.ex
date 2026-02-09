defmodule EchsCli.Tui.Events do
  @moduledoc """
  PubSub event draining and thread event dispatch for the TUI.
  """

  alias EchsCli.Tui.Helpers
  alias EchsCli.Tui.Model.Message

  @poll_max_events 200

  @doc """
  Drain all pending PubSub messages from the process mailbox.
  """
  def drain_pubsub(model, remaining \\ @poll_max_events)
  def drain_pubsub(model, remaining) when remaining <= 0, do: model

  def drain_pubsub(model, remaining) do
    receive do
      {:turn_started, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:turn_completed, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:turn_delta, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:item_completed, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:tool_completed, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:turn_error, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:reasoning_delta, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:item_started, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:turn_interrupted, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:thread_created, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:thread_configured, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:thread_terminated, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:subagent_spawned, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
      {:subagent_down, _} = msg -> model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
    after
      0 -> model
    end
  end

  @doc """
  Handle a single thread event, updating the model accordingly.
  """
  def handle_thread_event(model, {:turn_started, %{thread_id: thread_id}}) do
    update_thread(model, thread_id, fn thread ->
      %{thread | status: :running, turn_started_at: System.monotonic_time(:millisecond)}
    end)
  end

  def handle_thread_event(model, {:turn_completed, %{thread_id: thread_id}}) do
    update_thread(model, thread_id, fn thread ->
      %{thread | status: :idle, turn_started_at: nil}
    end)
  end

  def handle_thread_event(model, {:turn_delta, %{thread_id: thread_id, content: delta}}) do
    update_thread(model, thread_id, fn thread ->
      %{thread | streaming: thread.streaming <> delta, scroll: :bottom, cache_dirty?: true}
    end)
  end

  def handle_thread_event(model, {:item_completed, %{thread_id: thread_id, item: item}}) do
    case item["type"] do
      "message" ->
        role = normalize_role(item["role"] || "assistant")
        text = extract_message_text(item)

        if text == "" do
          model
        else
          model
          |> add_message(thread_id, role, text)
          |> update_thread(thread_id, fn thread ->
            if role == :assistant do
              %{thread | streaming: "", scroll: :bottom, cache_dirty?: true}
            else
              thread
            end
          end)
        end

      "function_call" ->
        name = item["name"] || "tool"
        args = Helpers.truncate(item["arguments"] || "", 120)
        call_id = item["call_id"] || item["id"]

        add_message(model, thread_id, %Message{
          role: :tool_call,
          content: "#{name}(#{args})",
          tool_name: name,
          tool_args: args,
          call_id: call_id,
          status: :running,
          timestamp: System.monotonic_time(:millisecond)
        })

      "local_shell_call" ->
        cmd = get_in(item, ["action", "command"]) || []

        add_message(model, thread_id, %Message{
          role: :tool_call,
          content: "shell(#{Enum.join(cmd, " ")})",
          tool_name: "shell",
          tool_args: Enum.join(cmd, " "),
          status: :running,
          timestamp: System.monotonic_time(:millisecond)
        })

      "function_call_output" ->
        output = Helpers.truncate(item["output"] || "", 200)
        call_id = item["call_id"]

        model
        |> update_tool_call_status(thread_id, call_id, :success)
        |> add_message(thread_id, %Message{
          role: :tool_result,
          content: output,
          call_id: call_id,
          timestamp: System.monotonic_time(:millisecond)
        })

      "reasoning" ->
        summary = extract_reasoning_text(item)
        add_message(model, thread_id, :reasoning, summary)

      _ ->
        model
    end
  end

  def handle_thread_event(model, {:turn_error, %{thread_id: thread_id, error: error}}) do
    add_message(model, thread_id, :system, "Error: #{inspect(error)}")
  end

  def handle_thread_event(model, {:reasoning_delta, %{delta: delta}}) do
    info =
      if delta == "" do
        model.info
      else
        "Reasoning: #{Helpers.truncate(delta, 80)}"
      end

    %{model | info: info}
  end

  def handle_thread_event(model, {:turn_interrupted, %{thread_id: thread_id}}) do
    update_thread(model, thread_id, fn thread ->
      %{thread | status: :idle, turn_started_at: nil}
    end)
  end

  def handle_thread_event(model, {:subagent_spawned, %{thread_id: thread_id} = payload}) do
    task = Helpers.truncate(payload[:task] || payload["task"] || "unknown task", 80)
    agent_id = payload[:agent_id] || payload["agent_id"]

    add_message(model, thread_id, %Message{
      role: :subagent_spawned,
      content: task,
      agent_id: agent_id,
      timestamp: System.monotonic_time(:millisecond)
    })
  end

  def handle_thread_event(model, {:subagent_down, %{thread_id: thread_id} = payload}) do
    reason = to_string(payload[:reason] || payload["reason"] || "completed")
    agent_id = payload[:agent_id] || payload["agent_id"]

    add_message(model, thread_id, %Message{
      role: :subagent_down,
      content: reason,
      agent_id: agent_id,
      timestamp: System.monotonic_time(:millisecond)
    })
  end

  def handle_thread_event(model, {:item_started, %{item: %{"type" => "function_call", "name" => name}}}) do
    %{model | info: "Calling #{name}..."}
  end

  def handle_thread_event(model, {:thread_terminated, %{thread_id: thread_id}}) do
    model
    |> add_message(thread_id, :system, "Thread terminated")
    |> update_thread(thread_id, fn thread ->
      %{thread | status: :idle, turn_started_at: nil}
    end)
  end

  def handle_thread_event(model, _msg), do: model

  # --- Helpers ---

  def add_message(model, thread_id, %Message{} = msg) do
    update_thread(model, thread_id, fn thread ->
      %{
        thread
        | messages: thread.messages ++ [msg],
          scroll: :bottom,
          cache_dirty?: true
      }
    end)
  end

  def add_message(model, thread_id, role, content) when is_atom(role) do
    msg = %Message{
      role: role,
      content: content,
      timestamp: System.monotonic_time(:millisecond)
    }

    add_message(model, thread_id, msg)
  end

  def update_thread(model, thread_id, fun) do
    threads =
      Enum.map(model.threads, fn thread ->
        if thread.id == thread_id do
          fun.(thread)
        else
          thread
        end
      end)

    %{model | threads: threads}
  end

  defp update_tool_call_status(model, _thread_id, nil, _status), do: model

  defp update_tool_call_status(model, thread_id, call_id, status) do
    update_thread(model, thread_id, fn thread ->
      messages =
        Enum.map(thread.messages, fn msg ->
          if msg.role == :tool_call and msg.call_id == call_id do
            %{msg | status: status}
          else
            msg
          end
        end)

      %{thread | messages: messages, cache_dirty?: true}
    end)
  end

  def normalize_role("user"), do: :user
  def normalize_role("assistant"), do: :assistant
  def normalize_role(_), do: :assistant

  def extract_message_text(%{"content" => content}), do: extract_text_content(content)
  def extract_message_text(_), do: ""

  def extract_text_content(content) when is_binary(content), do: content

  def extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def extract_text_content(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  def extract_text_content(%{"text" => text}) when is_binary(text), do: text
  def extract_text_content(%{"content" => content}), do: extract_text_content(content)
  def extract_text_content(_), do: ""

  def extract_reasoning_text(%{"summary" => summary}) when is_list(summary) do
    summary
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def extract_reasoning_text(%{"summary" => summary}), do: to_string(summary)
  def extract_reasoning_text(%{"text" => text}), do: to_string(text)
  def extract_reasoning_text(%{"delta" => delta}), do: to_string(delta)

  def extract_reasoning_text(summary) when is_list(summary) do
    summary
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def extract_reasoning_text(other), do: to_string(other)
end
