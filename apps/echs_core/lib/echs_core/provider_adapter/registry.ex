defmodule EchsCore.ProviderAdapter.Registry do
  @moduledoc """
  Registry for provider adapters. Dispatches to the appropriate adapter
  based on model name.

  ## Built-in Adapters

  - `EchsCore.ProviderAdapter.OpenAI` — handles `gpt-*`, `o3*`, `o4*` models
  - `EchsCore.ProviderAdapter.Anthropic` — handles `claude-*`, `opus`, `sonnet`, `haiku` models

  ## Custom Adapters

  Additional adapters can be registered at runtime:

      ProviderAdapter.Registry.register(MyCustomAdapter)
  """

  @builtin_adapters [
    EchsCore.ProviderAdapter.OpenAI,
    EchsCore.ProviderAdapter.Anthropic
  ]

  @doc """
  Find the adapter module for a given model string.
  Returns `{:ok, module}` or `{:error, :no_adapter}`.
  """
  @spec adapter_for(String.t()) :: {:ok, module()} | {:error, :no_adapter}
  def adapter_for(model) when is_binary(model) do
    adapters = all_adapters()

    case Enum.find(adapters, & &1.handles_model?(model)) do
      nil -> {:error, :no_adapter}
      adapter -> {:ok, adapter}
    end
  end

  @doc """
  Find the adapter for a model and start a stream.
  Convenience function combining lookup + dispatch.
  """
  @spec start_stream(String.t(), EchsCore.ProviderAdapter.stream_opts()) ::
          EchsCore.ProviderAdapter.stream_result()
  def start_stream(model, opts) do
    case adapter_for(model) do
      {:ok, adapter} ->
        adapter.start_stream(Map.put(opts, :model, model))

      {:error, :no_adapter} ->
        {:error, %{status: 400, body: "No provider adapter for model: #{model}"}}
    end
  end

  @doc """
  Register a custom adapter module.
  """
  @spec register(module()) :: :ok
  def register(adapter_module) do
    current = Application.get_env(:echs_core, :custom_provider_adapters, [])

    unless adapter_module in current do
      Application.put_env(:echs_core, :custom_provider_adapters, [adapter_module | current])
    end

    :ok
  end

  @doc """
  List all registered adapters (custom first, then built-in).
  """
  @spec all_adapters() :: [module()]
  def all_adapters do
    custom = Application.get_env(:echs_core, :custom_provider_adapters, [])
    custom ++ @builtin_adapters
  end

  @doc """
  List all models supported by all registered adapters.
  """
  @spec all_models() :: [%{name: String.t(), provider: String.t()}]
  def all_models do
    all_adapters()
    |> Enum.flat_map(fn adapter ->
      info = adapter.provider_info()
      Enum.map(info.models, &%{name: &1, provider: info.name})
    end)
  end
end
