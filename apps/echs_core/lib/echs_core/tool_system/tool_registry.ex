defmodule EchsCore.ToolSystem.ToolRegistry do
  @moduledoc """
  Runtime registry for tool specifications per conversation.

  Manages the set of available tools with:
  - Registration with provenance tracking (built_in, remote, mcp, custom)
  - Runtime enable/disable per tool
  - Lookup by name
  - Filtering by provenance, enabled status, etc.
  - Thread-safe via GenServer per conversation
  """

  use GenServer

  alias EchsCore.ToolSystem.ToolSpec

  @type tool_entry :: %{
          spec: ToolSpec.t(),
          handler: term(),
          registered_at: non_neg_integer()
        }

  defstruct tools: %{}, conversation_id: nil

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    initial_tools = Keyword.get(opts, :tools, [])

    GenServer.start_link(__MODULE__, {conversation_id, initial_tools})
  end

  @doc """
  Register a tool. Returns `:ok` or `{:error, reason}`.
  """
  @spec register(GenServer.server(), map() | ToolSpec.t(), term()) :: :ok | {:error, term()}
  def register(registry, spec, handler \\ nil) do
    GenServer.call(registry, {:register, spec, handler})
  end

  @doc """
  Unregister a tool by name.
  """
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(registry, name) do
    GenServer.call(registry, {:unregister, name})
  end

  @doc """
  Enable a tool.
  """
  @spec enable(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def enable(registry, name) do
    GenServer.call(registry, {:set_enabled, name, true})
  end

  @doc """
  Disable a tool.
  """
  @spec disable(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def disable(registry, name) do
    GenServer.call(registry, {:set_enabled, name, false})
  end

  @doc """
  Look up a tool by name.
  """
  @spec lookup(GenServer.server(), String.t()) :: {:ok, tool_entry()} | {:error, :not_found}
  def lookup(registry, name) do
    GenServer.call(registry, {:lookup, name})
  end

  @doc """
  List all registered tools (optionally filtered).

  Options:
    * `:enabled_only` — only return enabled tools (default: true)
    * `:provenance` — filter by provenance (e.g., :built_in, :mcp)
  """
  @spec list(GenServer.server(), keyword()) :: [tool_entry()]
  def list(registry, opts \\ []) do
    GenServer.call(registry, {:list, opts})
  end

  @doc """
  Get tool specs in provider format (for API calls).
  """
  @spec provider_specs(GenServer.server()) :: [map()]
  def provider_specs(registry) do
    registry
    |> list(enabled_only: true)
    |> Enum.map(&ToolSpec.to_provider_format(&1.spec))
  end

  @doc """
  Get the handler for a tool by name.
  """
  @spec get_handler(GenServer.server(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def get_handler(registry, name) do
    case lookup(registry, name) do
      {:ok, entry} -> {:ok, entry.handler}
      error -> error
    end
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init({conversation_id, initial_tools}) do
    tools =
      Enum.reduce(initial_tools, %{}, fn tool, acc ->
        spec =
          case tool do
            %ToolSpec{} -> tool
            map when is_map(map) -> ToolSpec.from_legacy(map)
          end

        Map.put(acc, spec.name, %{
          spec: spec,
          handler: nil,
          registered_at: System.system_time(:millisecond)
        })
      end)

    {:ok, %__MODULE__{tools: tools, conversation_id: conversation_id}}
  end

  @impl true
  def handle_call({:register, spec_or_map, handler}, _from, state) do
    spec =
      case spec_or_map do
        %ToolSpec{} -> spec_or_map
        map when is_map(map) -> ToolSpec.from_legacy(map)
      end

    entry = %{
      spec: spec,
      handler: handler,
      registered_at: System.system_time(:millisecond)
    }

    tools = Map.put(state.tools, spec.name, entry)
    {:reply, :ok, %{state | tools: tools}}
  end

  def handle_call({:unregister, name}, _from, state) do
    tools = Map.delete(state.tools, name)
    {:reply, :ok, %{state | tools: tools}}
  end

  def handle_call({:set_enabled, name, enabled}, _from, state) do
    case Map.get(state.tools, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated = %{entry | spec: %{entry.spec | enabled: enabled}}
        tools = Map.put(state.tools, name, updated)
        {:reply, :ok, %{state | tools: tools}}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.get(state.tools, name) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    enabled_only = Keyword.get(opts, :enabled_only, true)
    provenance = Keyword.get(opts, :provenance)

    entries =
      state.tools
      |> Map.values()
      |> maybe_filter_enabled(enabled_only)
      |> maybe_filter_provenance(provenance)

    {:reply, entries, state}
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp maybe_filter_enabled(entries, true) do
    Enum.filter(entries, & &1.spec.enabled)
  end

  defp maybe_filter_enabled(entries, _), do: entries

  defp maybe_filter_provenance(entries, nil), do: entries

  defp maybe_filter_provenance(entries, prov) do
    Enum.filter(entries, &(&1.spec.provenance == prov))
  end
end
