defmodule EchsServer.Models do
  @moduledoc false

  @default_context_window 200_000

  @default_models [
    %{
      "id" => "gpt-5.2",
      "family" => "codex",
      "supports_reasoning" => true,
      "supports_tools" => true,
      "default_reasoning" => "medium",
      "context_window_tokens" => 200_000
    },
    %{
      "id" => "gpt-5.2-codex",
      "family" => "codex",
      "supports_reasoning" => true,
      "supports_tools" => true,
      "default_reasoning" => "medium",
      "context_window_tokens" => 200_000
    },
    %{
      "id" => "gpt-5.1-codex-mini",
      "family" => "codex",
      "supports_reasoning" => true,
      "supports_tools" => true,
      "default_reasoning" => "medium",
      "context_window_tokens" => 128_000
    },
    %{
      "id" => "opus",
      "family" => "claude",
      "supports_reasoning" => false,
      "supports_tools" => true,
      "context_window_tokens" => 200_000
    },
    %{
      "id" => "sonnet",
      "family" => "claude",
      "supports_reasoning" => false,
      "supports_tools" => true,
      "context_window_tokens" => 200_000
    },
    %{
      "id" => "haiku",
      "family" => "claude",
      "supports_reasoning" => false,
      "supports_tools" => true,
      "context_window_tokens" => 200_000
    }
  ]

  def catalog do
    %{
      items: list_models(),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def list_models do
    models = load_model_list()
    overrides = load_context_window_overrides()
    default_window = env_int("ECHS_MODEL_CONTEXT_WINDOW_DEFAULT", @default_context_window)

    Enum.map(models, fn model ->
      id = to_string(Map.get(model, "id") || Map.get(model, :id) || "")

      family =
        normalize_family(Map.get(model, "family") || Map.get(model, :family) || infer_family(id))

      label = Map.get(model, "label") || Map.get(model, :label)

      supports_reasoning =
        normalize_bool(
          Map.get(model, "supports_reasoning") || Map.get(model, :supports_reasoning)
        )

      supports_tools =
        normalize_bool(Map.get(model, "supports_tools") || Map.get(model, :supports_tools))

      default_reasoning =
        Map.get(model, "default_reasoning") || Map.get(model, :default_reasoning)

      window =
        normalize_window(
          Map.get(model, "context_window_tokens") ||
            Map.get(model, :context_window_tokens) ||
            Map.get(model, "contextWindowTokens") ||
            Map.get(model, :contextWindowTokens) ||
            Map.get(overrides, id) ||
            default_window
        )

      %{
        "id" => id,
        "family" => family,
        "label" => label,
        "supports_reasoning" => supports_reasoning || family == "codex",
        "supports_tools" => supports_tools != false,
        "default_reasoning" => default_reasoning,
        "context_window_tokens" => window
      }
    end)
  end

  def context_window_tokens(model_id) do
    id = to_string(model_id)

    case Enum.find(list_models(), fn model -> model["id"] == id end) do
      %{"context_window_tokens" => window} when is_integer(window) and window > 0 ->
        window

      _ ->
        env_int("ECHS_MODEL_CONTEXT_WINDOW_DEFAULT", @default_context_window)
    end
  end

  defp load_model_list do
    case System.get_env("ECHS_MODEL_CATALOG_JSON") do
      nil ->
        @default_models

      "" ->
        @default_models

      json ->
        case Jason.decode(json) do
          {:ok, %{"items" => items}} when is_list(items) -> items
          {:ok, %{"models" => items}} when is_list(items) -> items
          {:ok, items} when is_list(items) -> items
          _ -> @default_models
        end
    end
  end

  defp load_context_window_overrides do
    case System.get_env("ECHS_MODEL_CONTEXT_WINDOWS_JSON") do
      nil ->
        %{}

      "" ->
        %{}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = map} ->
            Enum.reduce(map, %{}, fn {key, value}, acc ->
              Map.put(acc, to_string(key), normalize_window(value))
            end)

          _ ->
            %{}
        end
    end
  end

  defp normalize_family(nil), do: "unknown"

  defp normalize_family(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_family()

  defp normalize_family(value) when is_binary(value), do: String.trim(value)
  defp normalize_family(_), do: "unknown"

  defp infer_family(model_id) when is_binary(model_id) do
    if String.starts_with?(String.downcase(model_id), "gpt-"), do: "codex", else: "unknown"
  end

  defp infer_family(_), do: "unknown"

  defp normalize_window(value) when is_integer(value) and value > 0, do: value
  defp normalize_window(value) when is_float(value) and value > 0, do: trunc(value)

  defp normalize_window(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> @default_context_window
    end
  end

  defp normalize_window(_), do: @default_context_window

  defp normalize_bool(nil), do: nil
  defp normalize_bool(value) when is_boolean(value), do: value

  defp normalize_bool(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp normalize_bool(_), do: nil

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end
end
