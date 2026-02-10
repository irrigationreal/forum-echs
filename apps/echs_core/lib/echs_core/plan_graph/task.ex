defmodule EchsCore.PlanGraph.Task do
  @moduledoc """
  Task struct for the plan/task graph data model.

  Tasks are the atomic units of work in the planning system. They have:
  - Dependencies on other tasks
  - Assignment to agents
  - Status lifecycle: pending -> assigned -> running -> completed/failed/blocked
  - Success criteria and evidence links (rune IDs)
  """

  @type status :: :pending | :assigned | :running | :completed | :failed | :blocked | :cancelled
  @type priority :: :critical | :high | :medium | :low

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          status: status(),
          priority: priority(),
          deps: [String.t()],
          owner: String.t() | nil,
          result: term(),
          evidence_rune_ids: [String.t()],
          success_criteria: String.t() | nil,
          created_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          metadata: map()
        }

  defstruct [
    :id,
    title: "",
    description: "",
    status: :pending,
    priority: :medium,
    deps: [],
    owner: nil,
    result: nil,
    evidence_rune_ids: [],
    success_criteria: nil,
    created_at_ms: 0,
    updated_at_ms: 0,
    metadata: %{}
  ]

  @doc "Create a new task with generated ID and current timestamp."
  @spec new(keyword()) :: t()
  def new(opts) do
    now = System.system_time(:millisecond)

    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      title: Keyword.get(opts, :title, ""),
      description: Keyword.get(opts, :description, ""),
      status: Keyword.get(opts, :status, :pending),
      priority: Keyword.get(opts, :priority, :medium),
      deps: Keyword.get(opts, :deps, []),
      owner: Keyword.get(opts, :owner),
      success_criteria: Keyword.get(opts, :success_criteria),
      created_at_ms: now,
      updated_at_ms: now,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Check if all dependencies are satisfied (completed)."
  @spec deps_satisfied?(t(), %{optional(String.t()) => t()}) :: boolean()
  def deps_satisfied?(%__MODULE__{deps: deps}, task_map) do
    Enum.all?(deps, fn dep_id ->
      case Map.get(task_map, dep_id) do
        %__MODULE__{status: :completed} -> true
        _ -> false
      end
    end)
  end

  @doc "Check if the task is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in [:completed, :failed, :cancelled]
  end

  @doc "Check if the task is runnable (pending with deps satisfied)."
  @spec runnable?(t(), %{optional(String.t()) => t()}) :: boolean()
  def runnable?(%__MODULE__{status: :pending} = task, task_map) do
    deps_satisfied?(task, task_map)
  end

  def runnable?(_, _), do: false

  defp generate_id, do: "task_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
