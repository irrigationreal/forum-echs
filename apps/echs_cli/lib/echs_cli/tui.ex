defmodule EchsCli.Tui do
  @moduledoc """
  Terminal UI for interacting with ECHS threads.
  Slim orchestrator that delegates to component modules.
  """

  @behaviour Ratatouille.App

  import Ratatouille.Constants, only: [key: 1]
  import Ratatouille.View

  alias ExTermbox.Event
  alias Ratatouille.Runtime.Command
  alias Ratatouille.Runtime.Subscription

  alias EchsCli.Tui.{Events, Helpers, InputBuffer}
  alias EchsCli.Tui.Model.{Message, ThreadView}
  alias EchsCli.Tui.Components.{InputArea, MessageList, StatusBar, ThreadSidebar}

  require Logger

  @grid_total 12
  @left_col 3
  @right_col 9
  @history_limit 2_000
  @poll_interval_ms 50
  @input_max_height 5

  def main(args \\ []) do
    Logger.configure(level: :warning)

    cwd =
      case args do
        [dir | _] -> Path.expand(dir)
        _ -> File.cwd!()
      end

    Application.put_env(:echs_cli, :tui_cwd, cwd)

    Ratatouille.run(__MODULE__,
      shutdown: :supervisor,
      quit_events: [
        {:key, key(:ctrl_c)},
        {:key, key(:esc)}
      ]
    )
  end

  # --- Ratatouille callbacks ---

  @impl true
  def init(%{window: window}) do
    ensure_started()

    cwd = Application.get_env(:echs_cli, :tui_cwd, File.cwd!())
    threads = load_threads(cwd)

    {threads, selected, command} =
      case threads do
        [] ->
          {:ok, thread_id} = EchsCore.create_thread(cwd: cwd)
          thread = new_thread(thread_id, cwd)
          :ok = EchsCore.subscribe(thread_id)
          cmd = Command.new(fn -> load_thread_history(thread_id) end, {:load_thread, thread_id})
          {[thread], 0, cmd}

        _ ->
          selected = 0
          thread = Enum.at(threads, selected)
          :ok = EchsCore.subscribe(thread.id)

          cmd =
            if thread.loaded? do
              nil
            else
              Command.new(fn -> load_thread_history(thread.id) end, {:load_thread, thread.id})
            end

          {threads, selected, cmd}
      end

    model = %{
      cwd: cwd,
      threads: threads,
      selected: selected,
      input: InputBuffer.new(),
      info: "Ready",
      window: window,
      tick: 0,
      command_history: [],
      history_index: -1
    }

    if is_nil(command), do: model, else: {model, command}
  end

  @impl true
  def subscribe(_model), do: Subscription.interval(@poll_interval_ms, :poll)

  @impl true
  def update(model, {:resize, %Event{w: w, h: h}}) do
    model
    |> mark_all_threads_dirty()
    |> Map.put(:window, %{width: w, height: h})
  end

  def update(model, {:event, %Event{} = event}), do: handle_key_event(model, event)

  def update(model, :poll) do
    model
    |> Map.update!(:tick, &(&1 + 1))
    |> Events.drain_pubsub()
  end

  # Thread events from Ratatouille command results
  def update(model, {tag, _} = msg) when tag in [
    :turn_started, :turn_completed, :turn_delta, :item_completed,
    :tool_completed, :turn_error, :reasoning_delta, :item_started,
    :turn_interrupted, :thread_created, :thread_configured,
    :thread_terminated, :subagent_spawned, :subagent_down
  ] do
    Events.handle_thread_event(model, msg)
  end

  def update(model, {{:load_thread, thread_id}, {:ok, items}}) do
    messages = history_items_to_messages(items)

    Events.update_thread(model, thread_id, fn thread ->
      %{thread | messages: messages, loaded?: true, scroll: :bottom, cache_dirty?: true}
    end)
  end

  def update(model, {{:load_thread, thread_id}, {:error, error}}) do
    model
    |> Events.update_thread(thread_id, fn thread -> %{thread | loaded?: true} end)
    |> Events.add_message(thread_id, :system, "Failed to load history: #{inspect(error)}")
  end

  def update(model, {{:create_thread, cwd}, {:ok, thread_id}}) do
    :ok = EchsCore.subscribe(thread_id)
    thread = new_thread(thread_id, cwd)
    threads = [thread | model.threads]
    model = %{model | threads: threads, selected: 0, info: "Thread #{Helpers.short_id(thread_id)}"}
    {model, Command.new(fn -> load_thread_history(thread_id) end, {:load_thread, thread_id})}
  end

  def update(model, {{:create_thread, _cwd}, {:error, error}}) do
    %{model | info: "Create thread failed: #{inspect(error)}"}
  end

  def update(model, {{:send_message, thread_id}, {:ok, _history}}) do
    Events.update_thread(model, thread_id, fn thread -> %{thread | status: :idle} end)
  end

  def update(model, {{:send_message, thread_id}, {:error, error}}) do
    model
    |> Events.update_thread(thread_id, fn thread -> %{thread | status: :error} end)
    |> Events.add_message(thread_id, :system, "Send failed: #{inspect(error)}")
  end

  def update(model, _msg), do: model

  # --- Render ---

  @impl true
  def render(model) do
    window = model.window
    {left_width, right_width} = column_widths(window)
    inner_width = max(1, right_width - 4)
    sidebar_width = max(1, left_width - 4)
    input_height = input_content_height(model)
    visible = panel_visible_lines(model)

    thread_labels = ThreadSidebar.render(model, sidebar_width)
    {msg_labels, msg_offset} = MessageList.build(model, inner_width, visible)
    input_labels = InputArea.render(model.input, window.width, input_height)

    t_bar = StatusBar.top_bar(model)
    b_bar = StatusBar.bottom_bar(model)

    view(top_bar: t_bar, bottom_bar: b_bar) do
      row do
        column(size: @grid_total) do
          row do
            column(size: @left_col) do
              panel(title: "Threads", height: :fill) do
                viewport(offset_y: thread_offset(model)) do
                  for label_el <- thread_labels do
                    label_el
                  end
                end
              end
            end

            column(size: @right_col) do
              panel(title: active_title(model), height: :fill) do
                viewport(offset_y: msg_offset) do
                  for label_el <- msg_labels do
                    label_el
                  end
                end
              end
            end
          end

          row do
            column(size: @grid_total) do
              panel(title: "❯ Compose", height: input_height + 2) do
                for label_el <- input_labels do
                  label_el
                end
              end
            end
          end
        end
      end
    end
  end

  # --- Key handling ---

  defp handle_key_event(model, %Event{ch: ch} = event) when ch > 0 do
    cond do
      ch in [?\r, ?\n] -> send_input(model)
      printable_event?(event) -> %{model | input: InputBuffer.append(model.input, ch)}
      true -> model
    end
  end

  defp handle_key_event(model, %Event{ch: 0, key: key_val}) when key_val in 32..126 do
    %{model | input: InputBuffer.append(model.input, key_val)}
  end

  defp handle_key_event(model, %Event{key: key_val} = event) do
    cond do
      key_val == key(:enter) -> send_input(model)
      key_val == key(:backspace) or key_val == key(:backspace2) ->
        %{model | input: InputBuffer.backspace(model.input)}
      key_val == key(:arrow_left) -> %{model | input: InputBuffer.move_left(model.input)}
      key_val == key(:arrow_right) -> %{model | input: InputBuffer.move_right(model.input)}
      key_val == key(:arrow_up) -> handle_up(model)
      key_val == key(:arrow_down) -> handle_down(model)
      key_val == key(:pgup) -> scroll_messages(model, -5)
      key_val == key(:pgdn) -> scroll_messages(model, 5)
      key_val == key(:ctrl_n) ->
        cmd = Command.new(fn -> EchsCore.create_thread(cwd: model.cwd) end, {:create_thread, model.cwd})
        {model, cmd}
      key_val == key(:tab) -> model
      key_val == key(:ctrl_o) -> %{model | input: InputBuffer.newline(model.input)}
      key_val == key(:ctrl_u) -> %{model | input: InputBuffer.clear(model.input)}
      key_val == key(:ctrl_l) -> model
      true -> handle_key_event(model, event |> Map.put(:ch, event.ch || 0))
    end
  end

  defp handle_key_event(model, _event), do: model

  defp handle_up(model) do
    input_text = InputBuffer.text(model.input)

    if input_text == "" and model.command_history != [] do
      # Browse command history
      new_idx = min(model.history_index + 1, length(model.command_history) - 1)
      cmd = Enum.at(model.command_history, new_idx, "")
      %{model | input: %InputBuffer{lines: [cmd], cursor_line: 0, cursor_col: String.length(cmd)}, history_index: new_idx}
    else
      select_thread(model, -1)
    end
  end

  defp handle_down(model) do
    if model.history_index >= 0 do
      new_idx = model.history_index - 1

      if new_idx < 0 do
        %{model | input: InputBuffer.new(), history_index: -1}
      else
        cmd = Enum.at(model.command_history, new_idx, "")
        %{model | input: %InputBuffer{lines: [cmd], cursor_line: 0, cursor_col: String.length(cmd)}, history_index: new_idx}
      end
    else
      select_thread(model, 1)
    end
  end

  # --- Actions ---

  defp send_input(%{threads: []} = model), do: model

  defp send_input(model) do
    input = InputBuffer.text(model.input)

    if input == "" do
      model
    else
      thread = Helpers.active_thread(model)

      # Add to command history
      history = [input | model.command_history] |> Enum.take(@history_limit)

      model =
        model
        |> Events.add_message(thread.id, :user, input)
        |> Events.update_thread(thread.id, fn t -> %{t | streaming: "", status: :running} end)

      command = Command.new(fn -> EchsCore.send_message(thread.id, input) end, {:send_message, thread.id})
      {%{model | input: InputBuffer.clear(model.input), command_history: history, history_index: -1}, command}
    end
  end

  defp select_thread(model, delta) do
    count = length(model.threads)

    if count == 0 do
      model
    else
      next = (model.selected + delta) |> max(0) |> min(count - 1)

      if next == model.selected do
        model
      else
        thread = Enum.at(model.threads, next)
        :ok = EchsCore.subscribe(thread.id)

        if thread.loaded? do
          %{model | selected: next}
        else
          cmd = Command.new(fn -> load_thread_history(thread.id) end, {:load_thread, thread.id})
          {%{model | selected: next}, cmd}
        end
      end
    end
  end

  defp scroll_messages(model, delta) do
    thread = Helpers.active_thread(model)

    if thread == nil do
      model
    else
      Events.update_thread(model, thread.id, fn t ->
        %{t | scroll: scroll_adjust(t.scroll, delta)}
      end)
    end
  end

  defp scroll_adjust(:bottom, delta) when delta < 0, do: 0
  defp scroll_adjust(:bottom, _delta), do: :bottom
  defp scroll_adjust(offset, delta) when is_integer(offset), do: max(0, offset + delta)

  defp printable_event?(%Event{ch: ch, key: key_val}), do: ch > 0 and key_val == 0

  # --- Layout helpers ---

  defp active_title(model) do
    case Helpers.active_thread(model) do
      nil -> "Chat"
      thread -> "Chat - #{thread.title}"
    end
  end

  defp column_widths(%{width: width}) do
    left = div(width * @left_col, @grid_total)
    right = max(1, width - left)
    {left, right}
  end

  defp input_content_height(model) do
    max(1, min(@input_max_height, model.window.height - 6))
  end

  defp input_panel_height(model), do: input_content_height(model) + 2

  defp panel_visible_lines(model) do
    max(1, model.window.height - input_panel_height(model) - 3)
  end

  defp thread_offset(model) do
    visible = panel_visible_lines(model)

    case {length(model.threads), visible} do
      {0, _} -> 0
      {_, 0} -> 0
      {count, _} -> max(0, min(model.selected - visible + 1, count - visible))
    end
  end

  defp mark_all_threads_dirty(model) do
    threads = Enum.map(model.threads, fn thread -> %{thread | cache_dirty?: true} end)
    %{model | threads: threads}
  end

  # --- Thread loading ---

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:echs_store)
    {:ok, _} = Application.ensure_all_started(:echs_core)
    {:ok, _} = Application.ensure_all_started(:echs_codex)
  end

  defp load_threads(cwd) do
    if Code.ensure_loaded?(EchsStore) and EchsStore.enabled?() do
      EchsStore.list_threads(limit: 200)
      |> Enum.map(fn thread ->
        %ThreadView{
          id: thread.thread_id,
          title: thread_title(thread.thread_id, thread.cwd || cwd)
        }
      end)
    else
      []
    end
  end

  defp new_thread(thread_id, cwd) do
    %ThreadView{
      id: thread_id,
      title: thread_title(thread_id, cwd),
      loaded?: true
    }
  end

  defp thread_title(thread_id, cwd) do
    base = Path.basename(cwd || "")
    if base == "", do: "Thread #{Helpers.short_id(thread_id)}", else: "#{Helpers.short_id(thread_id)} - #{base}"
  end

  defp load_thread_history(thread_id) do
    _ = EchsCore.restore_thread(thread_id)

    case EchsCore.get_history(thread_id, limit: @history_limit) do
      {:ok, %{items: items}} -> {:ok, items}
      {:ok, items} when is_list(items) -> {:ok, items}
      {:error, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp history_items_to_messages(items) when is_list(items) do
    Enum.flat_map(items, fn item ->
      case item["type"] do
        "message" ->
          role = Events.normalize_role(item["role"] || "assistant")
          text = Events.extract_message_text(item)
          if text == "", do: [], else: [%Message{role: role, content: text}]

        "function_call" ->
          name = item["name"] || "tool"
          args = Helpers.truncate(item["arguments"] || "", 120)
          call_id = item["call_id"] || item["id"]

          [%Message{role: :tool_call, content: "#{name}(#{args})", tool_name: name, tool_args: args, call_id: call_id, status: :success}]

        "local_shell_call" ->
          cmd = get_in(item, ["action", "command"]) || []
          [%Message{role: :tool_call, content: "shell(#{Enum.join(cmd, " ")})", tool_name: "shell", tool_args: Enum.join(cmd, " "), status: :success}]

        "function_call_output" ->
          output = Helpers.truncate(item["output"] || "", 200)
          call_id = item["call_id"]
          [%Message{role: :tool_result, content: output, call_id: call_id}]

        "reasoning" ->
          summary = Events.extract_reasoning_text(item)
          [%Message{role: :reasoning, content: summary}]

        _ ->
          []
      end
    end)
  end

  defp history_items_to_messages(_), do: []
end
