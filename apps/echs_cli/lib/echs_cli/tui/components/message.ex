defmodule EchsCli.Tui.Components.Message do
  @moduledoc """
  Per-message rendering with role-colored prefixes and word-wrapped content.
  Returns a list of label elements for a single message.
  """

  alias EchsCli.Tui.{Helpers, Theme, TextWrap}
  alias EchsCli.Tui.Components.{ToolCall, CodeBlock}
  alias EchsCli.Tui.Model.Message
  alias EchsCli.Tui.Markdown

  @doc """
  Render a single message into a list of label elements.
  `width` is the available content width.
  `opts` may contain `:tick` for spinner animation.
  """
  @spec render(Message.t() | map(), non_neg_integer(), keyword()) :: [Ratatouille.Renderer.Element.t()]
  def render(message, width, opts \\ [])

  def render(%Message{role: :tool_call} = msg, width, opts) do
    ToolCall.render_call(msg, width, opts)
  end

  def render(%Message{role: :tool_result} = msg, width, opts) do
    ToolCall.render_result(msg, width, opts)
  end

  def render(%Message{role: :subagent_spawned} = msg, width, _opts) do
    short_id = if msg.agent_id, do: String.slice(to_string(msg.agent_id), 0, 8), else: "????"
    task = Helpers.truncate(msg.content || "", max(1, width - 30))
    color = Theme.role_color(:subagent_spawned)

    [
      Helpers.build_label([
        {"   #{Theme.sym(:agent_spawn)} ", [color: color, attributes: [:bold]]},
        {"Spawned agent #{short_id}", [color: color, attributes: [:bold]]},
        {" #{Theme.sym(:tool_call)} ", [color: color]},
        {"\"#{task}\"", [color: color]}
      ])
    ]
  end

  def render(%Message{role: :subagent_down} = msg, width, _opts) do
    short_id = if msg.agent_id, do: String.slice(to_string(msg.agent_id), 0, 8), else: "????"
    _content = Helpers.truncate(msg.content || "", max(1, width - 30))
    color = Theme.role_color(:subagent_down)

    [
      Helpers.build_label([
        {"   #{Theme.sym(:agent_down)} ", [color: color, attributes: [:bold]]},
        {"Agent #{short_id} completed", [color: color]}
      ])
    ]
  end

  def render(%Message{} = msg, width, opts) do
    render_text_message(msg.role, msg.content, width, opts)
  end

  # Support legacy map format during migration
  def render(%{role: role, content: content}, width, opts) do
    render_text_message(role, content, width, opts)
  end

  defp render_text_message(role, content, width, opts) do
    prefix = Theme.role_prefix(role)
    prefix_len = String.length(prefix)
    color = Theme.role_color(role)
    content_width = max(1, width - prefix_len)

    if role == :assistant and Keyword.get(opts, :markdown, true) do
      render_markdown_message(prefix, prefix_len, color, content, content_width, width)
    else
      render_plain_message(prefix, prefix_len, color, content, content_width)
    end
  end

  defp render_plain_message(prefix, prefix_len, color, content, content_width) do
    lines = TextWrap.wrap_plain(to_string(content), content_width)
    indent = String.duplicate(" ", prefix_len)

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      if idx == 0 do
        Helpers.build_label([
          {prefix, [color: color, attributes: [:bold]]},
          {line, []}
        ])
      else
        Helpers.build_label([
          {indent, []},
          {line, []}
        ])
      end
    end)
  end

  defp render_markdown_message(prefix, prefix_len, color, content, content_width, full_width) do
    blocks = Markdown.parse(to_string(content))
    indent = String.duplicate(" ", prefix_len)

    {labels, _first} =
      Enum.reduce(blocks, {[], true}, fn block, {acc, is_first} ->
        case block do
          {:paragraph, spans} ->
            wrapped = TextWrap.wrap_spans(spans, content_width)

            new_labels =
              wrapped
              |> Enum.with_index()
              |> Enum.map(fn {line_spans, idx} ->
                pfx =
                  if is_first and idx == 0 do
                    [{prefix, [color: color, attributes: [:bold]]}]
                  else
                    [{indent, []}]
                  end

                Helpers.build_label(pfx ++ line_spans)
              end)

            {acc ++ new_labels, false}

          {:code_block, code, lang} ->
            code_labels = CodeBlock.render(code, lang, full_width)
            {acc ++ code_labels, false}
        end
      end)

    if labels == [], do: [Helpers.blank_label()], else: labels
  end
end
