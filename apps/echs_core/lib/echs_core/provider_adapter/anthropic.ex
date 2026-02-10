defmodule EchsCore.ProviderAdapter.Anthropic do
  @moduledoc """
  ProviderAdapter implementation for Anthropic/Claude Messages API.

  Wraps `EchsClaude.stream_response/1` and normalizes its SSE events
  into canonical ECHS stream events.

  ## Event Mapping

  | Anthropic SSE Event | Canonical Event |
  |---|---|
  | `content_block_delta` (text_delta) | `{:assistant_delta, ...}` |
  | `content_block_delta` (thinking_delta) | `{:reasoning_delta, ...}` |
  | `content_block_stop` (tool_use) | `{:tool_call, ...}` |
  | `message_stop` | `{:assistant_final, ...}` + `:done` |
  | `message_delta` (with usage) | `{:usage, ...}` |
  | error events | `{:error, ...}` |

  ## Error Mapping

  | Anthropic Error | Canonical Type | Retryable |
  |---|---|---|
  | 429 (rate limit) | `rate_limit` | true |
  | 401/403 | `auth` | false |
  | 408/504 (timeout) | `timeout` | true |
  | 500+ | `upstream_error` | true |
  | connection error | `connection_error` | true |
  """

  @behaviour EchsCore.ProviderAdapter

  alias EchsCore.ProviderAdapter.CanonicalEvents, as: CE

  @claude_model_prefixes ["claude-", "opus", "sonnet", "haiku"]

  @impl true
  def start_stream(opts) do
    on_event = opts.on_event

    # EchsClaude already translates to OpenAI-ish events, so we
    # normalize from those translated events to canonical events
    claude_on_event = fn event ->
      canonical_events = translate_event(event)

      Enum.reduce_while(canonical_events, :ok, fn canonical, _acc ->
        case on_event.(canonical) do
          :abort -> {:halt, :abort}
          _ -> {:cont, :ok}
        end
      end)
    end

    claude_opts = [
      model: opts.model,
      instructions: opts.instructions,
      input: opts.input,
      tools: opts.tools,
      reasoning: opts.reasoning,
      on_event: claude_on_event
    ]

    case EchsClaude.stream_response(claude_opts) do
      {:ok, response} ->
        {:ok, %{items: [], usage: extract_usage(response)}}

      {:error, %{status: status, body: body}} ->
        on_event.(translate_error(status, body))
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        on_event.(CE.error("connection_error", inspect(reason), true))
        {:error, reason}
    end
  end

  @impl true
  def cancel(_ref) do
    :ok
  end

  @impl true
  def provider_info do
    %{
      name: "anthropic",
      models: ["claude-opus-4", "claude-sonnet-4", "claude-haiku-3.5"],
      supports_reasoning: true,
      supports_streaming: true
    }
  end

  @impl true
  def handles_model?(model) do
    Enum.any?(@claude_model_prefixes, &String.starts_with?(model, &1))
  end

  # -------------------------------------------------------------------
  # Event translation
  #
  # EchsClaude normalizes Anthropic events to OpenAI-ish shapes.
  # We translate from those to canonical events.
  # -------------------------------------------------------------------

  # Text delta from EchsClaude's translation
  defp translate_event(%{"type" => "response.output_text.delta", "delta" => delta}) do
    [CE.assistant_delta(delta)]
  end

  # Item completed (function call or message)
  defp translate_event(%{"type" => "response.output_item.done", "item" => item}) do
    case item do
      %{"type" => "function_call", "call_id" => call_id, "name" => name, "arguments" => args} ->
        [CE.item_completed(item), CE.tool_call(call_id, name, args)]

      _ ->
        [CE.item_completed(item)]
    end
  end

  # Item started
  defp translate_event(%{"type" => "response.output_item.added", "item" => item}) do
    [CE.item_started(item)]
  end

  # Reasoning delta
  defp translate_event(%{
         "type" => "response.reasoning_summary_text.delta",
         "delta" => delta
       }) do
    [CE.reasoning_delta(delta)]
  end

  # Response completed
  defp translate_event(%{"type" => "response.completed", "response" => response}) do
    content = extract_content(response)
    items = Map.get(response, "output", [])
    events = [CE.assistant_final(content, items)]

    case response do
      %{"usage" => %{"input_tokens" => inp, "output_tokens" => out}} ->
        events ++ [CE.usage(inp, out), CE.done()]

      _ ->
        events ++ [CE.done()]
    end
  end

  defp translate_event(%{"type" => "done"}) do
    [CE.done()]
  end

  defp translate_event(%{"type" => "error", "message" => message}) do
    [CE.error("upstream_error", message, true)]
  end

  defp translate_event(_), do: []

  # -------------------------------------------------------------------
  # Error translation
  # -------------------------------------------------------------------

  defp translate_error(429, body) do
    CE.error("rate_limit", error_message(body), true)
  end

  defp translate_error(status, body) when status in [401, 403] do
    CE.error("auth", error_message(body), false)
  end

  defp translate_error(status, body) when status in [408, 504] do
    CE.error("timeout", error_message(body), true)
  end

  defp translate_error(status, body) when status >= 500 do
    CE.error("upstream_error", "HTTP #{status}: #{error_message(body)}", true)
  end

  defp translate_error(status, body) do
    CE.error("provider_error", "HTTP #{status}: #{error_message(body)}", false)
  end

  defp error_message(body) when is_binary(body), do: body
  defp error_message(body), do: inspect(body)

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

  defp extract_content(%{"output" => output}) when is_list(output) do
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

  defp extract_content(_), do: ""
end
