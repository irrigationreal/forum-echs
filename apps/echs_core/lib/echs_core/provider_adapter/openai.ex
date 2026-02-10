defmodule EchsCore.ProviderAdapter.OpenAI do
  @moduledoc """
  ProviderAdapter implementation for OpenAI/Codex Responses API.

  Wraps `EchsCodex.Responses.stream_response/1` and normalizes its
  SSE events into canonical ECHS stream events.

  ## Event Mapping

  | OpenAI SSE Event | Canonical Event |
  |---|---|
  | `response.output_text.delta` | `{:assistant_delta, ...}` |
  | `response.output_item.done` (message) | `{:item_completed, ...}` |
  | `response.output_item.done` (function_call) | `{:tool_call, ...}` |
  | `response.completed` | `{:assistant_final, ...}` + `:done` |
  | `done` / `[DONE]` | `:done` |
  | `response.reasoning_summary_text.delta` | `{:reasoning_delta, ...}` |
  | `error` | `{:error, ...}` |
  """

  @behaviour EchsCore.ProviderAdapter

  alias EchsCore.ProviderAdapter.CanonicalEvents, as: CE

  @codex_models ["gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2", "gpt-5.1", "gpt-4.1",
                  "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "o3", "o3-mini", "o4-mini"]

  @impl true
  def start_stream(opts) do
    on_event = opts.on_event

    codex_on_event = fn event ->
      canonical_events = translate_event(event)

      Enum.reduce_while(canonical_events, :ok, fn canonical, _acc ->
        case on_event.(canonical) do
          :abort -> {:halt, :abort}
          _ -> {:cont, :ok}
        end
      end)
    end

    codex_opts = [
      model: opts.model,
      instructions: opts.instructions,
      input: opts.input,
      tools: opts.tools,
      reasoning: opts.reasoning,
      on_event: codex_on_event
    ]

    case EchsCodex.stream_response(codex_opts) do
      {:ok, response} ->
        {:ok, %{items: [], usage: extract_usage(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cancel(_ref) do
    # Cancellation is handled by the stream control mechanism in StreamRunner
    :ok
  end

  @impl true
  def provider_info do
    %{
      name: "openai",
      models: @codex_models,
      supports_reasoning: true,
      supports_streaming: true
    }
  end

  @impl true
  def handles_model?(model) do
    String.starts_with?(model, "gpt-") or
      String.starts_with?(model, "o3") or
      String.starts_with?(model, "o4") or
      model in @codex_models
  end

  # -------------------------------------------------------------------
  # Event translation
  # -------------------------------------------------------------------

  defp translate_event(%{"type" => "response.output_text.delta", "delta" => delta}) do
    [CE.assistant_delta(delta)]
  end

  defp translate_event(%{"type" => "response.output_item.done", "item" => item}) do
    case item do
      %{"type" => "function_call", "call_id" => call_id, "name" => name, "arguments" => args} ->
        [CE.item_completed(item), CE.tool_call(call_id, name, args)]

      %{"type" => "message"} ->
        [CE.item_completed(item)]

      _ ->
        [CE.item_completed(item)]
    end
  end

  defp translate_event(%{"type" => "response.output_item.added", "item" => item}) do
    [CE.item_started(item)]
  end

  defp translate_event(%{
         "type" => "response.reasoning_summary_text.delta",
         "delta" => delta
       }) do
    [CE.reasoning_delta(delta)]
  end

  defp translate_event(%{"type" => "response.completed", "response" => response}) do
    usage = extract_response_usage(response)
    content = extract_response_content(response)
    items = Map.get(response, "output", [])

    events = [CE.assistant_final(content, items)]
    events = if usage, do: events ++ [CE.usage(usage.input, usage.output)], else: events
    events ++ [CE.done()]
  end

  defp translate_event(%{"type" => "done"}) do
    [CE.done()]
  end

  defp translate_event(%{"type" => "error", "message" => message}) do
    [CE.error("provider_error", message, false)]
  end

  defp translate_event(_event) do
    # Unknown event types are silently ignored
    []
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp extract_usage(%{body: %{"usage" => usage}}) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0
    }
  end

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp extract_response_usage(%{"usage" => %{"input_tokens" => inp, "output_tokens" => out}}) do
    %{input: inp, output: out}
  end

  defp extract_response_usage(_), do: nil

  defp extract_response_content(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => content} when is_list(content) ->
        Enum.map(content, fn
          %{"text" => text} -> text
          _ -> ""
        end)

      _ ->
        []
    end)
    |> Enum.join("")
  end

  defp extract_response_content(_), do: ""
end
