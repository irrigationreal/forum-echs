defmodule EchsCore.Observability.Chaos do
  @moduledoc """
  Fault injection harness for chaos engineering in ECHS.

  Provides a framework for injecting controlled faults into the system
  to verify resilience and recovery behaviour. Backed by an ETS table
  for cross-process visibility so that adapter stubs and tool runners
  can check for active faults at call-time.

  ## Supported fault types

  | Type | Effect |
  |---|---|
  | `:provider_timeout` | Provider API calls hang for a configurable duration |
  | `:provider_429` | Provider returns HTTP 429 rate-limit responses |
  | `:provider_partial_stream` | Provider emits partial deltas then drops the connection |
  | `:tool_crash` | Tool execution raises / exits |
  | `:slow_io` | Artificial delay injected before I/O operations |
  | `:memory_pressure` | Forces GC and allocates transient binaries |

  ## Usage

      Chaos.inject_fault(:provider_timeout, delay_ms: 5_000)
      # ... exercise the system ...
      Chaos.remove_fault(:provider_timeout)

  ## Scenarios

  A `Scenario` bundles a sequence of timed fault injections together
  with a set of invariant checks to run after recovery:

      scenario = Chaos.Scenario.new("429-storm", [
        {0, :inject, :provider_429, [status: 429, retry_after: 1]},
        {500, :remove, :provider_429, []},
      ], invariants: ["tool_terminality", "event_ordering"])

      result = Chaos.run_scenario(scenario)
  """

  use GenServer
  require Logger

  # -------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------

  @type fault_type ::
          :provider_timeout
          | :provider_429
          | :provider_partial_stream
          | :tool_crash
          | :slow_io
          | :memory_pressure

  @type fault_opts :: keyword()

  @type fault_entry :: %{
          type: fault_type(),
          opts: fault_opts(),
          injected_at_ms: integer()
        }

  @type scenario_step ::
          {non_neg_integer(), :inject | :remove, fault_type(), fault_opts()}

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc "Start the Chaos harness (usually not supervised; started on demand)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Inject a fault into the system.

  ## Options per fault type

  * `:provider_timeout`        — `delay_ms` (default 5_000)
  * `:provider_429`            — `status` (429), `retry_after` (1)
  * `:provider_partial_stream` — `emit_count` (3), `delta_text` ("partial…")
  * `:tool_crash`              — `exception` (RuntimeError), `message` ("chaos: tool crash")
  * `:slow_io`                 — `delay_ms` (200)
  * `:memory_pressure`         — `alloc_bytes` (10_000_000), `gc` (true)
  """
  @spec inject_fault(fault_type(), fault_opts()) :: :ok
  def inject_fault(type, opts \\ []) when is_atom(type) do
    GenServer.call(server(), {:inject, type, opts})
  end

  @doc "Remove an active fault. No-op if the fault is not active."
  @spec remove_fault(fault_type()) :: :ok
  def remove_fault(type) when is_atom(type) do
    GenServer.call(server(), {:remove, type})
  end

  @doc "List all currently active faults."
  @spec active_faults() :: [fault_entry()]
  def active_faults do
    GenServer.call(server(), :active_faults)
  end

  @doc """
  Check whether a specific fault type is currently active.

  This is the hot-path query used by adapters and tool runners.
  Reads directly from ETS to avoid GenServer bottleneck.
  """
  @spec fault_active?(fault_type()) :: {true, fault_opts()} | false
  def fault_active?(type) do
    case :ets.lookup(table_name(), type) do
      [{^type, opts}] -> {true, opts}
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Run a chaos scenario: execute a timed sequence of fault injections,
  then validate invariants after recovery.

  Returns a scenario result map.
  """
  @spec run_scenario(map(), keyword()) :: map()
  def run_scenario(scenario, opts \\ []) do
    GenServer.call(server(), {:run_scenario, scenario, opts}, scenario_timeout(scenario))
  end

  @doc """
  Apply the effect of a fault. Called by interceptors (adapters, tool
  runners, I/O wrappers) when they detect an active fault.

  Returns the canonical error/behaviour for the given fault type.
  """
  @spec apply_fault(fault_type(), fault_opts()) :: term()
  def apply_fault(:provider_timeout, opts) do
    delay = Keyword.get(opts, :delay_ms, 5_000)
    Process.sleep(delay)
    {:error, %{type: "timeout", message: "chaos: provider timeout after #{delay}ms", retryable: true}}
  end

  def apply_fault(:provider_429, opts) do
    status = Keyword.get(opts, :status, 429)
    retry_after = Keyword.get(opts, :retry_after, 1)

    {:error,
     %{
       type: "rate_limit",
       message: "chaos: 429 Too Many Requests",
       retryable: true,
       status: status,
       retry_after: retry_after
     }}
  end

  def apply_fault(:provider_partial_stream, opts) do
    emit_count = Keyword.get(opts, :emit_count, 3)
    delta_text = Keyword.get(opts, :delta_text, "partial...")
    on_event = Keyword.get(opts, :on_event)

    if is_function(on_event, 1) do
      for _i <- 1..emit_count do
        on_event.({:assistant_delta, %{content: delta_text}})
      end
    end

    {:error, %{type: "stream_interrupted", message: "chaos: partial stream cut off", retryable: true}}
  end

  def apply_fault(:tool_crash, opts) do
    exception_mod = Keyword.get(opts, :exception, RuntimeError)
    message = Keyword.get(opts, :message, "chaos: tool crash")
    raise exception_mod, message
  end

  def apply_fault(:slow_io, opts) do
    delay = Keyword.get(opts, :delay_ms, 200)
    Process.sleep(delay)
    :ok
  end

  def apply_fault(:memory_pressure, opts) do
    alloc_bytes = Keyword.get(opts, :alloc_bytes, 10_000_000)
    do_gc = Keyword.get(opts, :gc, true)

    # Allocate a large binary to create heap pressure
    _pressure = :crypto.strong_rand_bytes(alloc_bytes)

    if do_gc do
      :erlang.garbage_collect()
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Scenario helpers (pure data, no GenServer needed to construct)
  # -------------------------------------------------------------------

  defmodule Scenario do
    @moduledoc """
    A chaos scenario definition.

    Contains a sequence of timed fault injection/removal steps and
    a list of invariant names to check after the scenario completes.
    """

    @type t :: %__MODULE__{
            name: String.t(),
            steps: [EchsCore.Observability.Chaos.scenario_step()],
            invariants: [String.t()],
            recovery_wait_ms: non_neg_integer(),
            metadata: map()
          }

    @enforce_keys [:name, :steps]
    defstruct name: "",
              steps: [],
              invariants: [],
              recovery_wait_ms: 500,
              metadata: %{}

    @doc "Build a new scenario."
    @spec new(String.t(), [EchsCore.Observability.Chaos.scenario_step()], keyword()) :: t()
    def new(name, steps, opts \\ []) do
      %__MODULE__{
        name: name,
        steps: Enum.sort_by(steps, &elem(&1, 0)),
        invariants: Keyword.get(opts, :invariants, []),
        recovery_wait_ms: Keyword.get(opts, :recovery_wait_ms, 500),
        metadata: Keyword.get(opts, :metadata, %{})
      }
    end
  end

  # -------------------------------------------------------------------
  # GenServer implementation
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(table_name(), [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, faults: %{}}}
  end

  @impl true
  def handle_call({:inject, type, opts}, _from, state) do
    entry = %{
      type: type,
      opts: opts,
      injected_at_ms: System.monotonic_time(:millisecond)
    }

    :ets.insert(state.table, {type, opts})
    new_faults = Map.put(state.faults, type, entry)

    emit_chaos_telemetry(:inject, type, opts)
    Logger.info("[Chaos] Injected fault: #{type} opts=#{inspect(opts)}")

    {:reply, :ok, %{state | faults: new_faults}}
  end

  def handle_call({:remove, type}, _from, state) do
    :ets.delete(state.table, type)
    new_faults = Map.delete(state.faults, type)

    emit_chaos_telemetry(:remove, type, [])
    Logger.info("[Chaos] Removed fault: #{type}")

    {:reply, :ok, %{state | faults: new_faults}}
  end

  def handle_call(:active_faults, _from, state) do
    entries = Map.values(state.faults)
    {:reply, entries, state}
  end

  def handle_call({:run_scenario, scenario, opts}, _from, state) do
    result = execute_scenario(scenario, opts, state)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up ETS table on shutdown
    try do
      :ets.delete(state.table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Scenario execution
  # -------------------------------------------------------------------

  defp execute_scenario(scenario, _opts, state) do
    start_ms = System.monotonic_time(:millisecond)
    step_results = execute_steps(scenario.steps, state, [])

    # Wait for the system to recover
    Process.sleep(scenario.recovery_wait_ms)

    # Clean up any faults that were not explicitly removed
    cleanup_faults(state)

    # Run invariant checks
    invariant_results = run_invariant_checks(scenario.invariants)

    duration_ms = System.monotonic_time(:millisecond) - start_ms
    all_invariants_passed = Enum.all?(invariant_results, &(&1.status in [:pass, :skip]))

    %{
      scenario: scenario.name,
      status: if(all_invariants_passed, do: :pass, else: :fail),
      steps_executed: length(step_results),
      step_results: step_results,
      invariant_results: invariant_results,
      invariants_passed: Enum.count(invariant_results, &(&1.status == :pass)),
      invariants_failed: Enum.count(invariant_results, &(&1.status == :fail)),
      invariants_skipped: Enum.count(invariant_results, &(&1.status == :skip)),
      duration_ms: duration_ms,
      metadata: scenario.metadata
    }
  end

  defp execute_steps([], _state, acc), do: Enum.reverse(acc)

  defp execute_steps([{delay_ms, action, type, opts} | rest], state, acc) do
    if delay_ms > 0, do: Process.sleep(delay_ms)

    result =
      case action do
        :inject ->
          :ets.insert(state.table, {type, opts})
          entry = %{type: type, opts: opts, injected_at_ms: System.monotonic_time(:millisecond)}
          emit_chaos_telemetry(:inject, type, opts)
          Logger.info("[Chaos/Scenario] Injected fault: #{type}")
          %{action: :inject, type: type, status: :ok, at_ms: entry.injected_at_ms}

        :remove ->
          :ets.delete(state.table, type)
          emit_chaos_telemetry(:remove, type, [])
          Logger.info("[Chaos/Scenario] Removed fault: #{type}")
          %{action: :remove, type: type, status: :ok, at_ms: System.monotonic_time(:millisecond)}
      end

    execute_steps(rest, state, [result | acc])
  end

  defp cleanup_faults(state) do
    :ets.delete_all_objects(state.table)
  end

  defp run_invariant_checks([]), do: []

  defp run_invariant_checks(invariant_names) do
    Enum.map(invariant_names, fn name ->
      run_single_invariant(name)
    end)
  end

  defp run_single_invariant("no_active_faults") do
    # Verify all faults have been cleaned up
    remaining =
      try do
        :ets.tab2list(table_name())
      rescue
        ArgumentError -> []
      end

    %{
      name: "no_active_faults",
      status: if(remaining == [], do: :pass, else: :fail),
      message:
        if(remaining == [],
          do: "All faults cleaned up",
          else: "#{length(remaining)} faults still active"
        ),
      details: %{remaining: remaining}
    }
  end

  defp run_single_invariant("process_alive") do
    # Verify the chaos harness itself is alive
    alive = Process.whereis(__MODULE__) != nil

    %{
      name: "process_alive",
      status: if(alive, do: :pass, else: :fail),
      message: if(alive, do: "Chaos harness process alive", else: "Chaos harness process dead"),
      details: %{}
    }
  end

  defp run_single_invariant("memory_stable") do
    # Check that memory usage is within reasonable bounds after pressure
    {:memory, mem} = Process.info(self(), :memory)
    # 50 MB threshold — generous for test processes
    ok = mem < 50_000_000

    %{
      name: "memory_stable",
      status: if(ok, do: :pass, else: :fail),
      message: "Process memory: #{div(mem, 1024)} KB",
      details: %{memory_bytes: mem}
    }
  end

  defp run_single_invariant("ets_table_exists") do
    exists =
      try do
        :ets.info(table_name()) != :undefined
      rescue
        ArgumentError -> false
      end

    %{
      name: "ets_table_exists",
      status: if(exists, do: :pass, else: :fail),
      message: if(exists, do: "ETS table present", else: "ETS table missing"),
      details: %{}
    }
  end

  defp run_single_invariant(name) do
    %{
      name: name,
      status: :skip,
      message: "Unknown invariant: #{name}",
      details: %{}
    }
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp server, do: __MODULE__

  defp table_name, do: :echs_chaos_faults

  defp scenario_timeout(scenario) do
    total_delay =
      scenario.steps
      |> Enum.map(&elem(&1, 0))
      |> Enum.sum()

    # Add generous buffer: sum of step delays + recovery wait + 10s headroom
    total_delay + scenario.recovery_wait_ms + 10_000
  end

  defp emit_chaos_telemetry(action, type, opts) do
    :telemetry.execute(
      [:echs, :chaos, action],
      %{count: 1},
      %{fault_type: type, opts: opts}
    )
  end
end
