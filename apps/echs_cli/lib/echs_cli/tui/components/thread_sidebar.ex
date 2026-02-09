defmodule EchsCli.Tui.Components.ThreadSidebar do
  @moduledoc """
  Color-coded thread list sidebar with spinners for running threads.
  """

  alias EchsCli.Tui.{Helpers, Theme}
  alias Ratatouille.Renderer.Element

  @doc """
  Renders the list of threads as styled label elements.
  Returns a list of `%Element{tag: :label}`.
  """
  @spec render(map(), non_neg_integer()) :: [Element.t()]
  def render(model, available_width) do
    if model.threads == [] do
      [Helpers.plain_label("(no threads)")]
    else
      model.threads
      |> Enum.with_index()
      |> Enum.map(fn {thread, idx} ->
        render_thread_line(thread, idx, model.selected, model.tick, available_width)
      end)
    end
  end

  defp render_thread_line(thread, idx, selected, tick, available_width) do
    is_selected = idx == selected

    prefix =
      cond do
        thread.status == :running -> " #{Theme.spinner_frame(tick)} "
        is_selected -> " #{Theme.sym(:thread_active)} "
        true -> " #{Theme.sym(:thread_idle)} "
      end

    title = Helpers.truncate(thread.title || thread.id, max(1, available_width - String.length(prefix)))

    color =
      cond do
        is_selected -> Theme.role_color(:tool_result)
        thread.status == :running -> Theme.thread_color(:running)
        thread.status == :error -> Theme.thread_color(:error)
        true -> Theme.thread_color(:idle)
      end

    attrs = if is_selected, do: [:bold], else: []

    Helpers.build_label([{prefix <> title, [color: color, attributes: attrs]}])
  end
end
