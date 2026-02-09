defmodule EchsCli.Tui.Components.ToolCall do
  @moduledoc """
  Renders tool call and tool result messages with structured visual blocks.
  """

  alias EchsCli.Tui.{Helpers, Theme}
  alias EchsCli.Tui.Model.Message

  import Ratatouille.Constants, only: [color: 1]

  @doc """
  Render a tool call as a styled block.
  Format: `   → tool_name  description  ✔`
  """
  @spec render_call(Message.t(), non_neg_integer(), keyword()) :: [Ratatouille.Renderer.Element.t()]
  def render_call(%Message{} = msg, _width, opts) do
    tick = Keyword.get(opts, :tick, 0)
    name = msg.tool_name || "tool"
    description = format_tool_args(name, msg.tool_args || "")

    status_text =
      case msg.status do
        :running -> Theme.spinner_frame(tick)
        :success -> Theme.tool_status_icon(:success)
        :error -> Theme.tool_status_icon(:error)
        _ -> ""
      end

    status_color =
      case msg.status do
        :running -> Theme.role_color(:tool_call)
        :success -> color(:green)
        :error -> color(:red)
        _ -> color(:white)
      end

    desc_part = if description != "", do: "  #{description}", else: ""

    [
      Helpers.build_label([
        {"   #{Theme.sym(:tool_call)} ", [color: Theme.role_color(:tool_call), attributes: [:bold]]},
        {name, [color: Theme.role_color(:tool_call), attributes: [:bold]]},
        {desc_part, [color: color(:white)]},
        {"  #{status_text}", [color: status_color]}
      ])
    ]
  end

  @doc """
  Render a tool result with indented output.
  Format: `   ← truncated_output`
  """
  @spec render_result(Message.t(), non_neg_integer(), keyword()) :: [Ratatouille.Renderer.Element.t()]
  def render_result(%Message{} = msg, _width, _opts) do
    content = format_tool_result(msg.content || "", 200)

    [
      Helpers.build_label([
        {"   #{Theme.sym(:tool_result)} ", [color: Theme.role_color(:tool_result), attributes: [:bold]]},
        {content, [color: Theme.role_color(:tool_result)]}
      ])
    ]
  end

  @doc false
  def format_tool_args(name, raw_args) do
    case Jason.decode(raw_args) do
      {:ok, parsed} -> format_parsed_args(name, parsed)
      _ -> Helpers.truncate(raw_args, 60)
    end
  end

  defp format_parsed_args("read_file", %{"path" => path}), do: Helpers.truncate(path, 60)
  defp format_parsed_args("read_file", %{"file_path" => path}), do: Helpers.truncate(path, 60)

  defp format_parsed_args("shell", %{"command" => cmd}) when is_list(cmd),
    do: Helpers.truncate(Enum.join(cmd, " "), 60)

  defp format_parsed_args("shell", %{"command" => cmd}),
    do: Helpers.truncate(to_string(cmd), 60)

  defp format_parsed_args("exec_command", %{"command" => cmd}) when is_list(cmd),
    do: Helpers.truncate(Enum.join(cmd, " "), 60)

  defp format_parsed_args("exec_command", %{"command" => cmd}),
    do: Helpers.truncate(to_string(cmd), 60)

  defp format_parsed_args("grep_files", %{"pattern" => pattern, "path" => path}),
    do: Helpers.truncate("#{pattern} in #{path}", 60)

  defp format_parsed_args("grep_files", %{"pattern" => pattern}),
    do: Helpers.truncate(pattern, 60)

  defp format_parsed_args("spawn_agent", %{"task" => task}),
    do: Helpers.truncate(task, 60)

  defp format_parsed_args(_name, parsed) when is_map(parsed) do
    case Map.to_list(parsed) do
      [{key, val}] -> Helpers.truncate("#{key}=#{val}", 60)
      [{key, val} | _] -> Helpers.truncate("#{key}=#{val}", 60)
      _ -> ""
    end
  end

  defp format_parsed_args(_name, _parsed), do: ""

  @doc false
  def format_tool_result(content, max_len) do
    case Jason.decode(content) do
      {:ok, %{"summary" => summary}} when is_binary(summary) ->
        Helpers.truncate(summary, max_len)

      {:ok, %{"output" => output}} when is_binary(output) ->
        Helpers.truncate(output, max_len)

      {:ok, %{"result" => result}} when is_binary(result) ->
        Helpers.truncate(result, max_len)

      _ ->
        Helpers.truncate(content, max_len)
    end
  end
end
