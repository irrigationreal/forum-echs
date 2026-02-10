defmodule EchsCore.ProviderAdapter do
  @moduledoc """
  Behaviour defining the interface for LLM provider integrations.

  Each provider adapter normalizes provider-specific streaming into
  canonical ECHS stream events, enabling the TurnEngine and EventPipeline
  to work identically regardless of which LLM provider is backing a
  conversation.

  ## Canonical Stream Events

  All adapters must emit events matching these types:

  | Event Type | Description |
  |---|---|
  | `{:assistant_delta, %{content: binary}}` | Streaming text fragment |
  | `{:assistant_final, %{content: binary, items: list}}` | Final assembled output |
  | `{:tool_call, %{call_id: binary, name: binary, arguments: binary}}` | Model requests tool call |
  | `{:reasoning_delta, %{content: binary}}` | Reasoning/thinking fragment (if supported) |
  | `{:usage, %{input_tokens: integer, output_tokens: integer}}` | Token usage report |
  | `{:error, %{type: binary, message: binary, retryable: boolean}}` | Provider error |
  | `:done` | Stream has ended normally |

  ## Implementation Notes

  - Adapters should translate provider-specific errors into canonical error events
  - The `start_stream/2` function runs synchronously in a Task — it should
    call `on_event` for each event and return when the stream is complete
  - `cancel/1` should be callable from any process to abort an active stream
  """

  @type stream_opts :: %{
          model: String.t(),
          instructions: String.t(),
          input: [map()],
          tools: [map()],
          reasoning: String.t(),
          on_event: (term() -> :ok | :abort)
        }

  @type cancel_ref :: reference() | pid()

  @type stream_result ::
          {:ok, %{items: [map()], usage: map()}}
          | {:error, %{status: integer(), body: term()}}
          | {:error, term()}

  @type provider_info :: %{
          name: String.t(),
          models: [String.t()],
          supports_reasoning: boolean(),
          supports_streaming: boolean()
        }

  @doc """
  Start a streaming request to the provider.

  Called from within a Task. Should invoke `opts.on_event` for each
  canonical event. Returns when the stream is complete.

  The function should handle:
  - SSE parsing and event normalization
  - Error translation to canonical error events
  - Usage extraction and reporting
  - Graceful handling of cancellation (check for abort return from on_event)
  """
  @callback start_stream(stream_opts()) :: stream_result()

  @doc """
  Cancel an active stream. Must be safe to call from any process.
  Returns `:ok` immediately; the stream task will terminate at the
  next safe boundary.
  """
  @callback cancel(cancel_ref()) :: :ok

  @doc """
  Return metadata about this provider (name, supported models, capabilities).
  """
  @callback provider_info() :: provider_info()

  @doc """
  Return true if this adapter handles the given model string.
  Used for adapter dispatch based on model name.
  """
  @callback handles_model?(String.t()) :: boolean()

  @optional_callbacks [cancel: 1]
end
