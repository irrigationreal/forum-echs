defmodule EchsCli.Tui do
  @moduledoc """
  Terminal UI for interacting with ECHS threads.
  """

  @behaviour Ratatouille.App

  import Ratatouille.Constants, only: [color: 1, key: 1]
  import Ratatouille.View

  alias ExTermbox.Event
  alias Ratatouille.Runtime.Command
  alias Ratatouille.Runtime.Subscription

  require Logger

  @grid_total 12
  @left_col 3
  @right_col 9
  @input_prefix "> "
  @history_limit 2_000
  @poll_interval_ms 50
  @poll_max_events 200
  @input_max_height 5

  defmodule ThreadView do
    @moduledoc false

    defstruct id: nil,
              title: nil,
              messages: [],
              streaming: "",
              loaded?: false,
              scroll: :bottom,
              status: :idle,
              cache_width: nil,
              cache_lines: [],
              cache_dirty?: true
  end

  defmodule InputBuffer do
    @moduledoc false

    defstruct lines: [""]

    def new, do: %__MODULE__{}

    def append(%__MODULE__{} = buf, ch) when is_integer(ch), do: append(buf, <<ch>>)

    def append(%__MODULE__{} = buf, ch) when is_binary(ch) do
      {last, rest} = List.pop_at(buf.lines, -1)
      last = last || ""
      %{buf | lines: rest ++ [last <> ch]}
    end

    def newline(%__MODULE__{} = buf), do: %{buf | lines: buf.lines ++ [""]}

    def backspace(%__MODULE__{} = buf) do
      {last, rest} = List.pop_at(buf.lines, -1)
      last = last || ""

      cond do
        last == "" and rest != [] ->
          %{buf | lines: rest}

        last == "" ->
          buf

        true ->
          trimmed = String.slice(last, 0, max(0, String.length(last) - 1))
          %{buf | lines: rest ++ [trimmed]}
      end
    end

    def clear(_buf), do: %__MODULE__{}

    def text(%__MODULE__{} = buf) do
      buf.lines
      |> Enum.join("\n")
      |> String.trim()
    end
  end

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
      window: window
    }

    if is_nil(command), do: model, else: {model, command}
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(@poll_interval_ms, :poll)
  end

  @impl true
  def update(model, {:resize, %Event{w: w, h: h}}) do
    model
    |> mark_all_threads_dirty()
    |> Map.put(:window, %{width: w, height: h})
  end

  def update(model, {:event, %Event{} = event}) do
    handle_key_event(model, event)
  end

  def update(model, :poll) do
    drain_pubsub(model, @poll_max_events)
  end

  def update(model, {:turn_started, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:turn_completed, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:turn_delta, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:item_completed, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:tool_completed, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:turn_error, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:reasoning_delta, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:item_started, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:turn_interrupted, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:thread_created, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:thread_configured, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:thread_terminated, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:subagent_spawned, _data} = msg), do: handle_thread_event(model, msg)
  def update(model, {:subagent_down, _data} = msg), do: handle_thread_event(model, msg)

  def update(model, {{:load_thread, thread_id}, {:ok, items}}) do
    messages = history_items_to_messages(items)

    update_thread(model, thread_id, fn thread ->
      %{thread | messages: messages, loaded?: true, scroll: :bottom, cache_dirty?: true}
    end)
  end

  def update(model, {{:load_thread, thread_id}, {:error, error}}) do
    model
    |> update_thread(thread_id, fn thread -> %{thread | loaded?: true} end)
    |> add_message(thread_id, :system, "Failed to load history: #{inspect(error)}")
  end

  def update(model, {{:create_thread, cwd}, {:ok, thread_id}}) do
    :ok = EchsCore.subscribe(thread_id)
    thread = new_thread(thread_id, cwd)
    threads = [thread | model.threads]

    model = %{model | threads: threads, selected: 0, info: "Thread #{short_id(thread_id)}"}

    {model, Command.new(fn -> load_thread_history(thread_id) end, {:load_thread, thread_id})}
  end

  def update(model, {{:create_thread, _cwd}, {:error, error}}) do
    %{model | info: "Create thread failed: #{inspect(error)}"}
  end

  def update(model, {{:send_message, thread_id}, {:ok, _history}}) do
    update_thread(model, thread_id, fn thread -> %{thread | status: :idle} end)
  end

  def update(model, {{:send_message, thread_id}, {:error, error}}) do
    model
    |> update_thread(thread_id, fn thread -> %{thread | status: :error} end)
    |> add_message(thread_id, :system, "Send failed: #{inspect(error)}")
  end

  def update(model, _msg), do: model

  @impl true
  def render(model) do
    window = model.window
    {left_width, right_width} = column_widths(window)

    threads_text = thread_list_text(model, left_width)
    {messages_text, msg_offset} = messages_view(model, right_width)
    input_height = input_content_height(model)
    input_lines = input_lines_for_display(model.input, window.width, input_height)

    top_bar =
      bar do
        label(
          content:
            "ECHS TUI  Ctrl-N=new  Up/Down=switch  PgUp/PgDn=scroll  Enter=send  Esc/Ctrl-C=quit  |  #{model.info}",
          color: color(:cyan),
          attributes: [:bold]
        )
      end

    view(top_bar: top_bar) do
      row do
        column(size: @grid_total) do
          row do
            column(size: @left_col) do
              panel(title: "Threads", height: :fill) do
                viewport(offset_y: thread_offset(model)) do
                  label(content: threads_text)
                end
              end
            end

            column(size: @right_col) do
              panel(title: active_title(model), height: :fill) do
                viewport(offset_y: msg_offset) do
                  label(content: messages_text)
                end
              end
            end
          end

          row do
            column(size: @grid_total) do
              panel(title: "Compose (Ctrl+O newline, Enter send)", height: input_height + 2) do
                label(content: Enum.join(input_lines, "\n"))
              end
            end
          end
        end
      end
    end
  end

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
          title: thread_title(thread.thread_id, thread.cwd || cwd),
          messages: [],
          streaming: "",
          loaded?: false,
          scroll: :bottom,
          status: :idle,
          cache_width: nil,
          cache_lines: [],
          cache_dirty?: true
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
      messages: [],
      streaming: "",
      loaded?: true,
      scroll: :bottom,
      status: :idle,
      cache_width: nil,
      cache_lines: [],
      cache_dirty?: true
    }
  end

  defp thread_title(thread_id, cwd) do
    base = Path.basename(cwd || "")

    if base == "" do
      "Thread #{short_id(thread_id)}"
    else
      "#{short_id(thread_id)} - #{base}"
    end
  end

  defp short_id("thr_" <> rest), do: String.slice(rest, 0, 8)
  defp short_id(id), do: String.slice(id, 0, 8)

  defp handle_key_event(model, %Event{ch: ch} = event) when ch > 0 do
    cond do
      ch in [?\r, ?\n] ->
        send_input(model)

      printable_event?(event) ->
        %{model | input: InputBuffer.append(model.input, ch)}

      true ->
        model
    end
  end

  defp handle_key_event(model, %Event{ch: 0, key: key_val}) when key_val in 32..126 do
    %{model | input: InputBuffer.append(model.input, key_val)}
  end

  defp handle_key_event(model, %Event{key: key_val} = event) do
    cond do
      key_val == key(:enter) ->
        send_input(model)

      key_val == key(:backspace) or key_val == key(:backspace2) ->
        %{model | input: InputBuffer.backspace(model.input)}

      key_val == key(:arrow_up) ->
        select_thread(model, -1)

      key_val == key(:arrow_down) ->
        select_thread(model, 1)

      key_val == key(:pgup) ->
        scroll_messages(model, -5)

      key_val == key(:pgdn) ->
        scroll_messages(model, 5)

      key_val == key(:ctrl_n) ->
        command =
          Command.new(
            fn -> EchsCore.create_thread(cwd: model.cwd) end,
            {:create_thread, model.cwd}
          )

        {model, command}

      key_val == key(:tab) ->
        model

      key_val == key(:ctrl_o) ->
        %{model | input: InputBuffer.newline(model.input)}

      key_val == key(:ctrl_u) ->
        %{model | input: InputBuffer.clear(model.input)}

      key_val == key(:ctrl_l) ->
        model

      true ->
        handle_key_event(model, event |> Map.put(:ch, event.ch || 0))
    end
  end

  defp handle_key_event(model, _event), do: model

  defp printable_event?(%Event{ch: ch, key: key_val}) do
    ch > 0 and key_val == 0
  end

  defp send_input(%{threads: []} = model), do: model

  defp send_input(model) do
    input = InputBuffer.text(model.input)

    if input == "" do
      model
    else
      thread = active_thread(model)

      model =
        model
        |> add_message(thread.id, :user, input)
        |> update_thread(thread.id, fn t -> %{t | streaming: "", status: :running} end)

      command =
        Command.new(fn -> EchsCore.send_message(thread.id, input) end, {:send_message, thread.id})

      {%{model | input: InputBuffer.clear(model.input)}, command}
    end
  end

  defp active_thread(model) do
    Enum.at(model.threads, model.selected)
  end

  defp active_title(model) do
    case active_thread(model) do
      nil -> "Chat"
      thread -> "Chat - #{thread.title}"
    end
  end

  defp select_thread(model, delta) do
    count = length(model.threads)

    if count == 0 do
      model
    else
      next =
        (model.selected + delta)
        |> max(0)
        |> min(count - 1)

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
    thread = active_thread(model)

    if thread == nil do
      model
    else
      update_thread(model, thread.id, fn t ->
        %{t | scroll: scroll_adjust(t.scroll, delta)}
      end)
    end
  end

  defp scroll_adjust(:bottom, delta) when delta < 0, do: 0
  defp scroll_adjust(:bottom, _delta), do: :bottom

  defp scroll_adjust(offset, delta) when is_integer(offset) do
    max(0, offset + delta)
  end

  defp add_message(model, thread_id, role, content) do
    update_thread(model, thread_id, fn thread ->
      %{
        thread
        | messages: thread.messages ++ [%{role: role, content: content}],
          scroll: :bottom,
          cache_dirty?: true
      }
    end)
  end

  defp update_thread(model, thread_id, fun) do
    {_, right_width} = column_widths(model.window)
    inner_width = max(1, right_width - 4)

    threads =
      Enum.map(model.threads, fn thread ->
        if thread.id == thread_id do
          thread
          |> fun.()
          |> maybe_rebuild_cache(inner_width)
        else
          thread
        end
      end)

    %{model | threads: threads}
  end

  defp maybe_rebuild_cache(thread, inner_width) do
    if thread.cache_dirty? or thread.cache_width != inner_width do
      rebuild_cache(thread, inner_width)
    else
      thread
    end
  end

  defp rebuild_cache(thread, inner_width) do
    lines = format_messages(thread.messages, thread.streaming, inner_width)
    %{thread | cache_width: inner_width, cache_lines: lines, cache_dirty?: false}
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
          role = (item["role"] || "assistant") |> normalize_role()
          text = extract_message_text(item)

          if text == "" do
            []
          else
            [%{role: role, content: text}]
          end

        "function_call" ->
          name = item["name"] || "tool"
          args = truncate(item["arguments"] || "", 120)
          [%{role: :tool, content: "Call #{name}(#{args})"}]

        "local_shell_call" ->
          cmd = get_in(item, ["action", "command"]) || []
          [%{role: :tool, content: "Shell: #{Enum.join(cmd, " ")}"}]

        "function_call_output" ->
          output = truncate(item["output"] || "", 200)
          [%{role: :tool, content: "Result: #{output}"}]

        "reasoning" ->
          summary = extract_reasoning_text(item)
          [%{role: :system, content: summary}]

        _ ->
          []
      end
    end)
  end

  defp history_items_to_messages(_), do: []

  defp thread_list_text(model, width) do
    threads = model.threads

    if threads == [] do
      "(no threads)"
    else
      available = max(1, width - 4)

      threads
      |> Enum.with_index()
      |> Enum.map(fn {thread, idx} ->
        prefix = if idx == model.selected, do: "> ", else: "  "
        status = if thread.status == :running, do: "* ", else: "  "
        line = prefix <> status <> (thread.title || thread.id)
        truncate(line, available)
      end)
      |> Enum.join("\n")
    end
  end

  defp thread_offset(model) do
    visible = panel_visible_lines(model)

    case {length(model.threads), visible} do
      {0, _} ->
        0

      {_, 0} ->
        0

      {count, _} ->
        max(0, min(model.selected - visible + 1, count - visible))
    end
  end

  defp panel_visible_lines(model) do
    max(1, model.window.height - input_panel_height(model) - 3)
  end

  defp messages_view(model, width) do
    thread = active_thread(model)

    if thread == nil do
      {"(no active thread)", 0}
    else
      inner_width = max(1, width - 4)
      visible = panel_visible_lines(model)

      lines =
        if thread.cache_width == inner_width and thread.cache_dirty? == false do
          thread.cache_lines
        else
          format_messages(thread.messages, thread.streaming, inner_width)
        end

      total = length(lines)
      max_offset = max(0, total - visible)

      offset =
        case thread.scroll do
          :bottom -> max_offset
          value when is_integer(value) -> min(max_offset, value)
          _ -> max_offset
        end

      {Enum.join(lines, "\n"), offset}
    end
  end

  defp format_messages(messages, streaming, width) do
    base_lines =
      messages
      |> Enum.flat_map(&format_message(&1, width))

    streaming_lines =
      if streaming != "" do
        format_message(%{role: :assistant, content: streaming}, width)
      else
        []
      end

    base_lines ++ streaming_lines
  end

  defp format_message(%{role: role, content: content}, width) do
    prefix =
      case role do
        :user -> "You: "
        :assistant -> "AI: "
        :tool -> "Tool: "
        :system -> "System: "
        _ -> "Note: "
      end

    wrap_with_prefix(prefix, content, width)
  end

  defp wrap_with_prefix(prefix, content, width) do
    prefix_width = String.length(prefix)
    available = max(1, width - prefix_width)

    lines = wrap_text(content, available)

    case lines do
      [] ->
        [prefix]

      [first | rest] ->
        [
          prefix <> first
          | Enum.map(rest, fn line -> String.duplicate(" ", prefix_width) <> line end)
        ]
    end
  end

  defp wrap_text(text, width) do
    text
    |> to_string()
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.flat_map(fn line -> wrap_line(line, width) end)
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp normalize_role(role) when is_binary(role) do
    case role do
      "user" -> :user
      "assistant" -> :assistant
      _ -> :assistant
    end
  end

  defp normalize_role(_), do: :assistant

  defp extract_message_text(%{"content" => content}), do: extract_text_content(content)
  defp extract_message_text(_), do: ""

  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp extract_text_content(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp extract_text_content(%{"text" => text}) when is_binary(text), do: text
  defp extract_text_content(%{"content" => content}), do: extract_text_content(content)
  defp extract_text_content(_), do: ""

  defp extract_reasoning_text(%{"summary" => summary}) when is_list(summary) do
    summary
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp extract_reasoning_text(%{"summary" => summary}), do: to_string(summary)
  defp extract_reasoning_text(%{"text" => text}), do: to_string(text)
  defp extract_reasoning_text(%{"delta" => delta}), do: to_string(delta)

  defp extract_reasoning_text(summary) when is_list(summary) do
    summary
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp extract_reasoning_text(other), do: to_string(other)

  defp truncate(value, max) do
    text = to_string(value || "")

    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
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

  defp input_panel_height(model) do
    input_content_height(model) + 2
  end

  defp input_lines_for_display(input, width, height) do
    inner_width = max(1, width - 4)
    lines = format_input_lines(input, inner_width)

    if length(lines) > height do
      Enum.take(lines, -height)
    else
      lines
    end
  end

  defp format_input_lines(%InputBuffer{lines: lines}, width) do
    cont_prefix = String.duplicate(" ", String.length(@input_prefix))

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      prefix = if idx == 0, do: @input_prefix, else: cont_prefix
      wrap_with_prefix(prefix, line, width)
    end)
  end

  defp mark_all_threads_dirty(model) do
    threads =
      Enum.map(model.threads, fn thread ->
        %{thread | cache_dirty?: true}
      end)

    %{model | threads: threads}
  end

  defp drain_pubsub(model, remaining) when remaining <= 0, do: model

  defp drain_pubsub(model, remaining) do
    receive do
      {:turn_started, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:turn_completed, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:turn_delta, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:item_completed, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:tool_completed, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:turn_error, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:reasoning_delta, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:item_started, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:turn_interrupted, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:thread_created, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:thread_configured, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:thread_terminated, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:subagent_spawned, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)

      {:subagent_down, _data} = msg ->
        model |> handle_thread_event(msg) |> drain_pubsub(remaining - 1)
    after
      0 ->
        model
    end
  end

  defp handle_thread_event(model, {:turn_started, %{thread_id: thread_id}}) do
    update_thread(model, thread_id, fn thread -> %{thread | status: :running} end)
  end

  defp handle_thread_event(model, {:turn_completed, %{thread_id: thread_id}}) do
    update_thread(model, thread_id, fn thread -> %{thread | status: :idle} end)
  end

  defp handle_thread_event(model, {:turn_delta, %{thread_id: thread_id, content: delta}}) do
    update_thread(model, thread_id, fn thread ->
      %{thread | streaming: thread.streaming <> delta, scroll: :bottom, cache_dirty?: true}
    end)
  end

  defp handle_thread_event(model, {:item_completed, %{thread_id: thread_id, item: item}}) do
    case item["type"] do
      "message" ->
        role = (item["role"] || "assistant") |> normalize_role()
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
        args = truncate(item["arguments"] || "", 120)
        add_message(model, thread_id, :tool, "Call #{name}(#{args})")

      "local_shell_call" ->
        cmd = get_in(item, ["action", "command"]) || []
        add_message(model, thread_id, :tool, "Shell: #{Enum.join(cmd, " ")}")

      "function_call_output" ->
        output = truncate(item["output"] || "", 200)
        add_message(model, thread_id, :tool, "Result: #{output}")

      "reasoning" ->
        summary = extract_reasoning_text(item)
        add_message(model, thread_id, :system, summary)

      _ ->
        model
    end
  end

  defp handle_thread_event(model, {:tool_completed, %{thread_id: thread_id, result: result}}) do
    add_message(model, thread_id, :tool, "Result: #{truncate(result, 200)}")
  end

  defp handle_thread_event(model, {:turn_error, %{thread_id: thread_id, error: error}}) do
    add_message(model, thread_id, :system, "Error: #{inspect(error)}")
  end

  defp handle_thread_event(model, {:reasoning_delta, %{delta: delta}}) do
    info =
      if delta == "" do
        model.info
      else
        "Reasoning: #{truncate(delta, 80)}"
      end

    %{model | info: info}
  end

  defp handle_thread_event(model, _msg), do: model
end
