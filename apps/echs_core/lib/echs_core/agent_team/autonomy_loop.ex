defmodule EchsCore.AgentTeam.AutonomyLoop do
  @moduledoc """
  Goal-directed autonomy loop: plan -> execute -> review -> iterate.

  Implements the scheduler that:
  1. Receives a goal and decomposes it into a plan (via orchestrator agent)
  2. Assigns runnable tasks to available agents
  3. Collects results and evidence
  4. Runs critique (optional)
  5. Determines next steps (more tasks, replan, goal met, stop)

  ## Stop Conditions

  - Goal met (all tasks completed, critique passed)
  - Budget exhausted (token/tool/time limits)
  - Blocked (all runnable tasks blocked on dependencies)
  - User interrupt
  - Max iterations reached

  ## State Machine

  `goal_received -> planning -> executing -> reviewing -> goal_met/stopped`
  """

  require Logger

  alias EchsCore.PlanGraph.{Plan, Task}
  # alias EchsCore.AgentTeam.Manager

  @type status :: :idle | :goal_received | :planning | :executing | :reviewing | :goal_met | :stopped

  @type config :: %{
          max_iterations: non_neg_integer(),
          auto_critique: boolean(),
          stop_on_first_failure: boolean()
        }

  @type t :: %__MODULE__{
          status: status(),
          plan: Plan.t() | nil,
          manager: GenServer.server() | nil,
          config: config(),
          iteration: non_neg_integer(),
          goal: String.t() | nil,
          stop_reason: String.t() | nil
        }

  defstruct [
    status: :idle,
    plan: nil,
    manager: nil,
    config: %{
      max_iterations: 10,
      auto_critique: true,
      stop_on_first_failure: false
    },
    iteration: 0,
    goal: nil,
    stop_reason: nil
  ]

  @doc """
  Create a new autonomy loop.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config =
      %{
        max_iterations: Keyword.get(opts, :max_iterations, 10),
        auto_critique: Keyword.get(opts, :auto_critique, true),
        stop_on_first_failure: Keyword.get(opts, :stop_on_first_failure, false)
      }

    %__MODULE__{
      config: config,
      manager: Keyword.get(opts, :manager)
    }
  end

  @doc """
  Set a goal and transition to :goal_received.
  """
  @spec set_goal(t(), String.t()) :: t()
  def set_goal(%__MODULE__{status: :idle} = loop, goal) do
    %{loop | status: :goal_received, goal: goal}
  end

  @doc """
  Set the plan and transition to :executing.
  """
  @spec set_plan(t(), Plan.t()) :: t()
  def set_plan(%__MODULE__{status: status} = loop, %Plan{} = plan)
      when status in [:goal_received, :planning, :reviewing] do
    %{loop | status: :executing, plan: plan}
  end

  @doc """
  Get the next batch of tasks to assign to agents.
  Returns runnable tasks sorted by priority.
  """
  @spec next_tasks(t()) :: [Task.t()]
  def next_tasks(%__MODULE__{plan: nil}), do: []

  def next_tasks(%__MODULE__{plan: plan}) do
    Plan.runnable_tasks(plan)
  end

  @doc """
  Record a task completion and advance the loop.
  """
  @spec complete_task(t(), String.t(), term()) :: t()
  def complete_task(%__MODULE__{plan: plan} = loop, task_id, result) do
    case Plan.update_task(plan, task_id, status: :completed, result: result) do
      {:ok, updated_plan} ->
        loop = %{loop | plan: updated_plan}
        maybe_advance(loop)

      {:error, :not_found} ->
        Logger.warning("AutonomyLoop: tried to complete unknown task #{task_id}")
        loop
    end
  end

  @doc """
  Record a task failure.
  """
  @spec fail_task(t(), String.t(), term()) :: t()
  def fail_task(%__MODULE__{plan: plan} = loop, task_id, error) do
    case Plan.update_task(plan, task_id, status: :failed, result: error) do
      {:ok, updated_plan} ->
        loop = %{loop | plan: updated_plan}

        if loop.config.stop_on_first_failure do
          stop(loop, "task_failed")
        else
          maybe_advance(loop)
        end

      {:error, :not_found} ->
        loop
    end
  end

  @doc """
  Stop the autonomy loop.
  """
  @spec stop(t(), String.t()) :: t()
  def stop(%__MODULE__{} = loop, reason) do
    %{loop | status: :stopped, stop_reason: reason}
  end

  @doc """
  Check if the loop is in a terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in [:goal_met, :stopped]
  end

  @doc """
  Get a summary of the current loop state.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = loop) do
    task_counts =
      if loop.plan do
        Plan.status_counts(loop.plan)
      else
        %{}
      end

    %{
      status: loop.status,
      goal: loop.goal,
      iteration: loop.iteration,
      task_counts: task_counts,
      stop_reason: loop.stop_reason
    }
  end

  # -------------------------------------------------------------------
  # Internal: state advancement
  # -------------------------------------------------------------------

  defp maybe_advance(%__MODULE__{plan: plan} = loop) do
    cond do
      # All tasks terminal
      Plan.all_terminal?(plan) ->
        if Plan.any_failed?(plan) do
          # Some tasks failed — check if we should replan
          if loop.iteration < loop.config.max_iterations do
            %{loop | status: :reviewing, iteration: loop.iteration + 1}
          else
            stop(loop, "max_iterations_reached")
          end
        else
          %{loop | status: :goal_met}
        end

      # No runnable tasks (all blocked)
      Plan.runnable_tasks(plan) == [] ->
        pending = Plan.status_counts(plan) |> Map.get(:pending, 0)

        if pending > 0 do
          stop(loop, "all_tasks_blocked")
        else
          stop(loop, "no_runnable_tasks")
        end

      # More tasks to do
      true ->
        loop
    end
  end
end
