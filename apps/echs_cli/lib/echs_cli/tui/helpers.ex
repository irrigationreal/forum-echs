defmodule EchsCli.Tui.Helpers do
  @moduledoc """
  Shared utility functions for building Ratatouille elements programmatically.
  """

  alias Ratatouille.Renderer.Element
  import Ratatouille.Constants, only: [color: 1]

  @doc """
  Build a label element from a list of `{content, style}` spans.
  Style is a keyword list with optional keys: :color, :background, :attributes.

  ## Example

      build_label([{"Hello ", color: :green, attributes: [:bold]}, {"world", []}])
  """
  @spec build_label([{String.t(), keyword()}]) :: Element.t()
  def build_label(spans) when is_list(spans) do
    children =
      Enum.map(spans, fn {content, style} ->
        attrs =
          %{content: to_string(content)}
          |> maybe_put(:color, resolve_color(style[:color]))
          |> maybe_put(:background, resolve_color(style[:background]))
          |> maybe_put(:attributes, style[:attributes])

        %Element{tag: :text, attributes: attrs, children: []}
      end)

    %Element{tag: :label, attributes: %{}, children: children}
  end

  @doc """
  Build a plain label with just text content.
  """
  @spec plain_label(String.t()) :: Element.t()
  def plain_label(content) do
    %Element{tag: :label, attributes: %{content: to_string(content)}, children: []}
  end

  @doc """
  Build an empty label (blank line separator).
  """
  @spec blank_label() :: Element.t()
  def blank_label do
    %Element{tag: :label, attributes: %{content: ""}, children: []}
  end

  @doc """
  Truncate a string to max length, adding "..." if truncated.
  """
  @spec truncate(String.t() | nil, non_neg_integer()) :: String.t()
  def truncate(value, max_len) do
    text = to_string(value || "")

    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  @doc """
  Shorten a thread ID for display.
  """
  @spec short_id(String.t()) :: String.t()
  def short_id("thr_" <> rest), do: String.slice(rest, 0, 8)
  def short_id(id), do: String.slice(to_string(id), 0, 8)

  @doc """
  Get the active thread from the model.
  """
  def active_thread(%{threads: threads, selected: selected}) do
    Enum.at(threads, selected)
  end

  defp resolve_color(nil), do: nil
  defp resolve_color(c) when is_integer(c), do: c
  defp resolve_color(c) when is_atom(c), do: color(c)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
