defmodule EchsCore.Hooks.Framework do
  @moduledoc """
  Hooks framework for event-driven actions.

  Supports hook triggers:
  - `:after_tool_result` — fired after a tool produces a result
  - `:turn_completed` — fired after a turn finishes
  - `:file_changed` — fired when a workspace file changes
  - `:task_completed` — fired when a plan task completes
  - `:agent_spawned` — fired when a new agent is created
  - `:checkpoint_created` — fired after a checkpoint is taken

  Hooks are registered per-conversation and can be:
  - Inline functions
  - Module/function references
  - Shell commands (executed via Runner)
  """

  use GenServer
  require Logger

  @type trigger :: :after_tool_result | :turn_completed | :file_changed |
                   :task_completed | :agent_spawned | :checkpoint_created

  @type hook_type :: :function | :mfa | :command

  @type hook :: %{
          hook_id: String.t(),
          trigger: trigger(),
          type: hook_type(),
          handler: term(),
          enabled: boolean(),
          priority: non_neg_integer(),
          description: String.t()
        }

  defstruct [
    hooks: %{},
    trigger_index: %{}
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Register a hook."
  @spec register(GenServer.server(), trigger(), term(), keyword()) :: {:ok, String.t()}
  def register(server, trigger, handler, opts \\ []) do
    GenServer.call(server, {:register, trigger, handler, opts})
  end

  @doc "Unregister a hook by ID."
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server, hook_id) do
    GenServer.call(server, {:unregister, hook_id})
  end

  @doc "Enable/disable a hook."
  @spec set_enabled(GenServer.server(), String.t(), boolean()) :: :ok
  def set_enabled(server, hook_id, enabled) do
    GenServer.call(server, {:set_enabled, hook_id, enabled})
  end

  @doc "Fire all hooks for a trigger with the given context."
  @spec fire(GenServer.server(), trigger(), map()) :: [{String.t(), :ok | {:error, term()}}]
  def fire(server, trigger, context \\ %{}) do
    GenServer.call(server, {:fire, trigger, context}, 30_000)
  end

  @doc "List all registered hooks."
  @spec list(GenServer.server()) :: [hook()]
  def list(server) do
    GenServer.call(server, :list)
  end

  @doc "List hooks for a specific trigger."
  @spec list_for_trigger(GenServer.server(), trigger()) :: [hook()]
  def list_for_trigger(server, trigger) do
    GenServer.call(server, {:list_for_trigger, trigger})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, trigger, handler, opts}, _from, state) do
    hook_id = generate_hook_id()
    type = infer_type(handler)

    hook = %{
      hook_id: hook_id,
      trigger: trigger,
      type: type,
      handler: handler,
      enabled: Keyword.get(opts, :enabled, true),
      priority: Keyword.get(opts, :priority, 100),
      description: Keyword.get(opts, :description, "")
    }

    hooks = Map.put(state.hooks, hook_id, hook)

    trigger_index =
      Map.update(state.trigger_index, trigger,
        MapSet.new([hook_id]), &MapSet.put(&1, hook_id))

    {:reply, {:ok, hook_id}, %{state | hooks: hooks, trigger_index: trigger_index}}
  end

  def handle_call({:unregister, hook_id}, _from, state) do
    case Map.get(state.hooks, hook_id) do
      nil ->
        {:reply, :ok, state}

      hook ->
        hooks = Map.delete(state.hooks, hook_id)
        trigger_index =
          Map.update(state.trigger_index, hook.trigger,
            MapSet.new(), &MapSet.delete(&1, hook_id))
        {:reply, :ok, %{state | hooks: hooks, trigger_index: trigger_index}}
    end
  end

  def handle_call({:set_enabled, hook_id, enabled}, _from, state) do
    case Map.get(state.hooks, hook_id) do
      nil ->
        {:reply, :ok, state}
      hook ->
        hooks = Map.put(state.hooks, hook_id, %{hook | enabled: enabled})
        {:reply, :ok, %{state | hooks: hooks}}
    end
  end

  def handle_call({:fire, trigger, context}, _from, state) do
    hook_ids = Map.get(state.trigger_index, trigger, MapSet.new())

    results =
      hook_ids
      |> MapSet.to_list()
      |> Enum.flat_map(fn id ->
        case Map.get(state.hooks, id) do
          nil -> []
          hook -> [hook]
        end
      end)
      |> Enum.filter(& &1.enabled)
      |> Enum.sort_by(& &1.priority)
      |> Enum.map(fn hook ->
        result = execute_hook(hook, context)
        {hook.hook_id, result}
      end)

    {:reply, results, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.hooks), state}
  end

  def handle_call({:list_for_trigger, trigger}, _from, state) do
    hook_ids = Map.get(state.trigger_index, trigger, MapSet.new())
    hooks = hook_ids |> MapSet.to_list() |> Enum.flat_map(fn id ->
      case Map.get(state.hooks, id) do
        nil -> []
        hook -> [hook]
      end
    end)
    {:reply, hooks, state}
  end

  # --- Internal ---

  defp execute_hook(%{type: :function, handler: fun}, context) when is_function(fun, 1) do
    try do
      fun.(context)
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp execute_hook(%{type: :mfa, handler: {m, f, a}}, context) do
    try do
      apply(m, f, [context | a])
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp execute_hook(%{type: :command, handler: command}, context) when is_binary(command) do
    try do
      env = [{"HOOK_TRIGGER", to_string(context[:trigger] || "")},
             {"HOOK_CONTEXT", Jason.encode!(context)}]
      {_output, exit_code} = System.cmd("sh", ["-c", command], env: env, stderr_to_stdout: true)
      if exit_code == 0, do: :ok, else: {:error, "command exited with #{exit_code}"}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp execute_hook(_, _), do: {:error, :unknown_handler_type}

  defp infer_type(handler) when is_function(handler), do: :function
  defp infer_type({m, f, _a}) when is_atom(m) and is_atom(f), do: :mfa
  defp infer_type(handler) when is_binary(handler), do: :command
  defp infer_type(_), do: :function

  defp generate_hook_id, do: "hook_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
