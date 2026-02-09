defmodule EchsCli.Tui.Components.MessageList do
  @moduledoc """
  Builds the scrollable message viewport from thread messages.
  Manages caching and scroll offset computation.
  """

  alias EchsCli.Tui.Components.Message, as: MessageComponent
  alias EchsCli.Tui.{Helpers, Theme}
  alias EchsCli.Tui.Model.Message
  alias Ratatouille.Renderer.Element

  @doc """
  Build the list of label elements for all messages + streaming buffer.
  Returns `{labels, offset}`.
  """
  @spec build(map(), non_neg_integer(), non_neg_integer()) ::
          {[Element.t()], non_neg_integer()}
  def build(model, inner_width, visible_lines) do
    thread = Helpers.active_thread(model)

    if thread == nil do
      {[Helpers.plain_label("(no active thread)")], 0}
    else
      labels = build_labels(thread, inner_width, model.tick)
      offset = compute_offset(thread.scroll, length(labels), visible_lines)
      {labels, offset}
    end
  end

  @doc """
  Build cached label elements for a thread (called during update_thread).
  """
  @spec build_cache(map(), non_neg_integer(), non_neg_integer()) :: [Element.t()]
  def build_cache(thread, inner_width, tick) do
    build_labels(thread, inner_width, tick)
  end

  defp build_labels(thread, inner_width, tick) do
    opts = [tick: tick, markdown: true]

    message_labels =
      thread.messages
      |> Enum.flat_map(fn msg ->
        labels = MessageComponent.render(msg, inner_width, opts)
        labels ++ [Helpers.blank_label()]
      end)

    streaming_labels =
      if thread.streaming != "" do
        streaming_msg = %Message{role: :assistant, content: thread.streaming}
        labels = MessageComponent.render(streaming_msg, inner_width, opts)

        # Append a blinking cursor block at the end
        cursor_label = Helpers.build_label([
          {Theme.role_prefix(:assistant), []},
          {Theme.spinner_frame(tick), [attributes: [:reverse]]}
        ])

        labels ++ [cursor_label]
      else
        thinking_labels(thread, tick)
      end

    message_labels ++ streaming_labels
  end

  defp thinking_labels(%{status: :running} = _thread, tick) do
    [
      Helpers.build_label([
        {Theme.role_prefix(:assistant), []},
        {"#{Theme.spinner_frame(tick)} Thinking", [attributes: [:bold]]}
      ])
    ]
  end

  defp thinking_labels(_thread, _tick), do: []

  defp compute_offset(:bottom, total, visible) do
    max(0, total - visible)
  end

  defp compute_offset(scroll, total, visible) when is_integer(scroll) do
    max_offset = max(0, total - visible)
    min(max_offset, scroll)
  end

  defp compute_offset(_, total, visible) do
    max(0, total - visible)
  end
end
