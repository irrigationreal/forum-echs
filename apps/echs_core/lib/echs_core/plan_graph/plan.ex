defmodule EchsCore.PlanGraph.Plan do
  @moduledoc """
  Plan data model with task graph management.

  A plan is a goal decomposed into tasks with dependencies. Plans are
  created, updated, and tracked via runes for deterministic replay.

  ## Status

  - `:planning` — plan being assembled
  - `:executing` — tasks being assigned and run
  - `:reviewing` — all tasks terminal, under critique
  - `:completed` — goal met
  - `:failed` — goal not achievable
  - `:stopped` — user/budget cancellation
  """

  alias EchsCore.PlanGraph.Task, as: PlanTask

  @type status :: :planning | :executing | :reviewing | :completed | :failed | :stopped

  @type t :: %__MODULE__{
          plan_id: String.t(),
          goal: String.t(),
          status: status(),
          tasks: %{optional(String.t()) => PlanTask.t()},
          task_order: [String.t()],
          created_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          metadata: map()
        }

  defstruct [
    :plan_id,
    goal: "",
    status: :planning,
    tasks: %{},
    task_order: [],
    created_at_ms: 0,
    updated_at_ms: 0,
    metadata: %{}
  ]

  @doc "Create a new plan."
  @spec new(String.t(), keyword()) :: t()
  def new(goal, opts \\ []) do
    now = System.system_time(:millisecond)

    %__MODULE__{
      plan_id: Keyword.get(opts, :plan_id, generate_id()),
      goal: goal,
      status: :planning,
      created_at_ms: now,
      updated_at_ms: now,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Add a task to the plan."
  @spec add_task(t(), PlanTask.t()) :: t()
  def add_task(%__MODULE__{} = plan, %PlanTask{} = task) do
    %{plan |
      tasks: Map.put(plan.tasks, task.id, task),
      task_order: plan.task_order ++ [task.id],
      updated_at_ms: System.system_time(:millisecond)
    }
  end

  @doc "Update a task in the plan."
  @spec update_task(t(), String.t(), keyword()) :: {:ok, t()} | {:error, :not_found}
  def update_task(%__MODULE__{} = plan, task_id, updates) do
    case Map.get(plan.tasks, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        updated_task =
          Enum.reduce(updates, task, fn
            {:status, v}, t -> %{t | status: v, updated_at_ms: System.system_time(:millisecond)}
            {:owner, v}, t -> %{t | owner: v, updated_at_ms: System.system_time(:millisecond)}
            {:result, v}, t -> %{t | result: v, updated_at_ms: System.system_time(:millisecond)}
            {:evidence_rune_ids, v}, t -> %{t | evidence_rune_ids: v}
            _, t -> t
          end)

        {:ok, %{plan |
          tasks: Map.put(plan.tasks, task_id, updated_task),
          updated_at_ms: System.system_time(:millisecond)
        }}
    end
  end

  @doc "Get all runnable tasks (pending with satisfied deps)."
  @spec runnable_tasks(t()) :: [PlanTask.t()]
  def runnable_tasks(%__MODULE__{tasks: tasks}) do
    tasks
    |> Map.values()
    |> Enum.filter(&PlanTask.runnable?(&1, tasks))
    |> Enum.sort_by(fn t ->
      priority_weight =
        case t.priority do
          :critical -> 0
          :high -> 1
          :medium -> 2
          :low -> 3
        end

      {priority_weight, t.created_at_ms}
    end)
  end

  @doc "Check if all tasks are in terminal states."
  @spec all_terminal?(t()) :: boolean()
  def all_terminal?(%__MODULE__{tasks: tasks}) do
    tasks |> Map.values() |> Enum.all?(&PlanTask.terminal?/1)
  end

  @doc "Check if any task has failed."
  @spec any_failed?(t()) :: boolean()
  def any_failed?(%__MODULE__{tasks: tasks}) do
    tasks |> Map.values() |> Enum.any?(&(&1.status == :failed))
  end

  @doc "Count tasks by status."
  @spec status_counts(t()) :: %{optional(PlanTask.status()) => non_neg_integer()}
  def status_counts(%__MODULE__{tasks: tasks}) do
    tasks
    |> Map.values()
    |> Enum.group_by(& &1.status)
    |> Map.new(fn {status, list} -> {status, length(list)} end)
  end

  defp generate_id, do: "plan_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
