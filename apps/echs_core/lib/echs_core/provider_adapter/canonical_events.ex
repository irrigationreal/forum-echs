defmodule EchsCore.ProviderAdapter.CanonicalEvents do
  @moduledoc """
  Canonical stream event constructors for provider adapters.

  These functions create properly structured events that all adapters
  must emit. Using these constructors ensures consistency.
  """

  @doc "Streaming text fragment from the assistant."
  @spec assistant_delta(String.t()) :: {:assistant_delta, %{content: String.t()}}
  def assistant_delta(content) when is_binary(content) do
    {:assistant_delta, %{content: content}}
  end

  @doc "Final assembled assistant output."
  @spec assistant_final(String.t(), [map()]) :: {:assistant_final, %{content: String.t(), items: [map()]}}
  def assistant_final(content, items \\ []) do
    {:assistant_final, %{content: content, items: items}}
  end

  @doc "Model requests a tool call."
  @spec tool_call(String.t(), String.t(), String.t() | map()) ::
          {:tool_call, %{call_id: String.t(), name: String.t(), arguments: term()}}
  def tool_call(call_id, name, arguments) do
    {:tool_call, %{call_id: call_id, name: name, arguments: arguments}}
  end

  @doc "Reasoning/thinking fragment."
  @spec reasoning_delta(String.t()) :: {:reasoning_delta, %{content: String.t()}}
  def reasoning_delta(content) when is_binary(content) do
    {:reasoning_delta, %{content: content}}
  end

  @doc "Token usage report."
  @spec usage(non_neg_integer(), non_neg_integer()) ::
          {:usage, %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}}
  def usage(input_tokens, output_tokens) do
    {:usage, %{input_tokens: input_tokens, output_tokens: output_tokens}}
  end

  @doc "Provider error."
  @spec error(String.t(), String.t(), boolean()) ::
          {:error, %{type: String.t(), message: String.t(), retryable: boolean()}}
  def error(type, message, retryable \\ false) do
    {:error, %{type: type, message: message, retryable: retryable}}
  end

  @doc "Stream completed normally."
  @spec done() :: :done
  def done, do: :done

  @doc "Output item started (for tracking multi-item responses)."
  @spec item_started(map()) :: {:item_started, map()}
  def item_started(item) when is_map(item) do
    {:item_started, item}
  end

  @doc "Output item completed."
  @spec item_completed(map()) :: {:item_completed, map()}
  def item_completed(item) when is_map(item) do
    {:item_completed, item}
  end
end
