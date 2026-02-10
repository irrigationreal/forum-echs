defmodule EchsCore.Observability.LoadTest do
  @moduledoc """
  Streaming scale test / load test harness (bd-0020).

  Self-contained load test framework for the ECHS event pipeline that
  simulates concurrent WebSocket/SSE clients, captures latency percentiles,
  memory usage, CPU load, and file descriptor counts, and generates a
  text-based pass/fail report against configurable thresholds.

  ## Architecture

      Scenario
        |
        +-- ConnectionSimulator (N supervised tasks)
        |     |-- subscribe/post_message/disconnect/reconnect cycles
        |     |-- records per-operation latency samples
        |
        +-- MetricsCollector (GenServer, ETS-backed)
        |     |-- accumulates latency histograms
        |     |-- polls system gauges (memory, FDs) on interval
        |
        +-- ReportGenerator
              |-- computes p50/p95/p99
              |-- checks pass/fail thresholds
              |-- outputs text summary

  ## Usage

      # Full-scale (1k clients, 30 min)
      scenario = LoadTest.Scenario.full_scale()
      {:ok, report} = LoadTest.run(scenario)
      IO.puts(LoadTest.ReportGenerator.format(report))

      # CI mode (10 clients, quick)
      scenario = LoadTest.Scenario.ci_small()
      {:ok, report} = LoadTest.run(scenario)

      # Custom
      scenario = %LoadTest.Scenario{
        connection_count: 50,
        active_turns: 10,
        duration_ms: 60_000,
        disconnect_probability: 0.05,
        turn_interval_ms: 200,
        thresholds: %{p95_latency_ms: 250, max_memory_growth_bytes: 50_000_000}
      }
      {:ok, report} = LoadTest.run(scenario)
  """

  alias EchsCore.Observability.LoadTest.{
    ConnectionSimulator,
    MetricsCollector,
    ReportGenerator,
    Scenario
  }

  require Logger

  @doc """
  Run a load test scenario end-to-end.

  Returns `{:ok, report}` where `report` is a map containing metrics,
  pass/fail results, and formatted text output.
  """
  @spec run(Scenario.t()) :: {:ok, map()} | {:error, term()}
  def run(%{__struct__: Scenario} = scenario) do
    Logger.info("[LoadTest] Starting scenario: #{scenario.name}")
    Logger.info("[LoadTest] Connections=#{scenario.connection_count} Duration=#{scenario.duration_ms}ms")

    with {:ok, collector} <- MetricsCollector.start_link(scenario),
         :ok <- MetricsCollector.snapshot_baseline(collector),
         {:ok, simulator} <- ConnectionSimulator.start_link(scenario, collector),
         :ok <- ConnectionSimulator.run(simulator, scenario),
         :ok <- ConnectionSimulator.await_completion(simulator, scenario.duration_ms + 30_000),
         metrics <- MetricsCollector.finalize(collector) do
      report = ReportGenerator.build(scenario, metrics)
      GenServer.stop(collector, :normal)

      Logger.info("[LoadTest] Complete: #{report.summary_line}")
      {:ok, report}
    end
  end
end

# ---------------------------------------------------------------------------
# Scenario
# ---------------------------------------------------------------------------

defmodule EchsCore.Observability.LoadTest.Scenario do
  @moduledoc """
  Configurable load test scenario.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          connection_count: pos_integer(),
          active_turns: pos_integer(),
          duration_ms: pos_integer(),
          disconnect_probability: float(),
          reconnect_delay_ms: pos_integer(),
          turn_interval_ms: pos_integer(),
          message_size_bytes: pos_integer(),
          ramp_up_ms: non_neg_integer(),
          poll_interval_ms: pos_integer(),
          thresholds: map()
        }

  defstruct name: "custom",
            connection_count: 10,
            active_turns: 5,
            duration_ms: 10_000,
            disconnect_probability: 0.05,
            reconnect_delay_ms: 500,
            turn_interval_ms: 200,
            message_size_bytes: 256,
            ramp_up_ms: 1_000,
            poll_interval_ms: 1_000,
            thresholds: %{
              p95_latency_ms: 250,
              max_memory_growth_bytes: 100_000_000
            }

  @doc "Full-scale scenario: 1k clients, 200 active turns, 30 min."
  @spec full_scale() :: t()
  def full_scale do
    %__MODULE__{
      name: "full_scale",
      connection_count: 1_000,
      active_turns: 200,
      duration_ms: 30 * 60 * 1_000,
      disconnect_probability: 0.02,
      reconnect_delay_ms: 1_000,
      turn_interval_ms: 150,
      message_size_bytes: 512,
      ramp_up_ms: 30_000,
      poll_interval_ms: 5_000,
      thresholds: %{
        p95_latency_ms: 250,
        max_memory_growth_bytes: 200_000_000
      }
    }
  end

  @doc "CI-friendly small scenario: 10 clients, quick run."
  @spec ci_small() :: t()
  def ci_small do
    %__MODULE__{
      name: "ci_small",
      connection_count: 10,
      active_turns: 5,
      duration_ms: 5_000,
      disconnect_probability: 0.1,
      reconnect_delay_ms: 200,
      turn_interval_ms: 100,
      message_size_bytes: 128,
      ramp_up_ms: 500,
      poll_interval_ms: 500,
      thresholds: %{
        p95_latency_ms: 500,
        max_memory_growth_bytes: 50_000_000
      }
    }
  end

  @doc "Medium scenario for local dev testing."
  @spec medium() :: t()
  def medium do
    %__MODULE__{
      name: "medium",
      connection_count: 100,
      active_turns: 30,
      duration_ms: 60_000,
      disconnect_probability: 0.05,
      reconnect_delay_ms: 500,
      turn_interval_ms: 200,
      message_size_bytes: 256,
      ramp_up_ms: 5_000,
      poll_interval_ms: 2_000,
      thresholds: %{
        p95_latency_ms: 250,
        max_memory_growth_bytes: 100_000_000
      }
    }
  end
end

# ---------------------------------------------------------------------------
# MetricsCollector
# ---------------------------------------------------------------------------

defmodule EchsCore.Observability.LoadTest.MetricsCollector do
  @moduledoc """
  ETS-backed metrics collector for load tests.

  Tracks latency histograms, connection counts, message throughput,
  and periodic system gauge snapshots (memory, file descriptors, CPU).
  """

  use GenServer

  @type t :: GenServer.server()

  defstruct [
    :table,
    :scenario,
    :baseline_memory,
    :baseline_fds,
    :gauge_snapshots,
    :start_time,
    :poll_timer
  ]

  @doc "Start the metrics collector."
  @spec start_link(EchsCore.Observability.LoadTest.Scenario.t()) :: GenServer.on_start()
  def start_link(scenario) do
    GenServer.start_link(__MODULE__, scenario)
  end

  @doc "Record a latency sample for a given operation."
  @spec record_latency(t(), atom(), number()) :: :ok
  def record_latency(collector, operation, latency_ms) when is_number(latency_ms) do
    GenServer.cast(collector, {:record_latency, operation, latency_ms})
  end

  @doc "Increment a counter for a given metric."
  @spec increment(t(), atom()) :: :ok
  def increment(collector, metric) do
    GenServer.cast(collector, {:increment, metric})
  end

  @doc "Increment a counter by an arbitrary amount."
  @spec increment_by(t(), atom(), pos_integer()) :: :ok
  def increment_by(collector, metric, amount) do
    GenServer.cast(collector, {:increment_by, metric, amount})
  end

  @doc "Snapshot current system state as baseline."
  @spec snapshot_baseline(t()) :: :ok
  def snapshot_baseline(collector) do
    GenServer.call(collector, :snapshot_baseline)
  end

  @doc "Finalize collection and return all metrics."
  @spec finalize(t()) :: map()
  def finalize(collector) do
    GenServer.call(collector, :finalize, 30_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init(scenario) do
    table = :ets.new(:load_test_metrics, [:set, :public])

    state = %__MODULE__{
      table: table,
      scenario: scenario,
      baseline_memory: 0,
      baseline_fds: 0,
      gauge_snapshots: [],
      start_time: System.monotonic_time(:millisecond),
      poll_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot_baseline, _from, state) do
    memory = current_memory_bytes()
    fds = current_fd_count()

    timer = Process.send_after(self(), :poll_gauges, state.scenario.poll_interval_ms)

    state = %{state |
      baseline_memory: memory,
      baseline_fds: fds,
      start_time: System.monotonic_time(:millisecond),
      poll_timer: timer
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)

    # Take one final gauge snapshot
    snapshot = take_gauge_snapshot(state)
    snapshots = state.gauge_snapshots ++ [snapshot]

    elapsed_ms = System.monotonic_time(:millisecond) - state.start_time

    latencies = read_all_latencies(state.table)
    counters = read_all_counters(state.table)

    memory_current = current_memory_bytes()
    memory_growth = memory_current - state.baseline_memory

    metrics = %{
      elapsed_ms: elapsed_ms,
      latencies: latencies,
      counters: counters,
      baseline_memory_bytes: state.baseline_memory,
      final_memory_bytes: memory_current,
      memory_growth_bytes: memory_growth,
      baseline_fds: state.baseline_fds,
      final_fds: current_fd_count(),
      gauge_snapshots: snapshots
    }

    :ets.delete(state.table)
    {:reply, metrics, state}
  end

  @impl true
  def handle_cast({:record_latency, operation, latency_ms}, state) do
    ets_key = {:latency, operation}

    try do
      existing = :ets.lookup_element(state.table, ets_key, 2)
      # Reservoir sampling: keep up to 10_000 samples per operation.
      # When full, randomly replace an existing sample to maintain
      # a representative distribution without unbounded memory growth.
      updated =
        if length(existing) >= 10_000 do
          idx = :rand.uniform(10_000) - 1
          List.replace_at(existing, idx, latency_ms)
        else
          [latency_ms | existing]
        end

      :ets.insert(state.table, {ets_key, updated})
    catch
      :error, :badarg ->
        :ets.insert(state.table, {ets_key, [latency_ms]})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:increment, metric}, state) do
    ets_key = {:counter, metric}

    try do
      :ets.update_counter(state.table, ets_key, {2, 1})
    catch
      :error, :badarg ->
        :ets.insert(state.table, {ets_key, 1})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:increment_by, metric, amount}, state) do
    ets_key = {:counter, metric}

    try do
      :ets.update_counter(state.table, ets_key, {2, amount})
    catch
      :error, :badarg ->
        :ets.insert(state.table, {ets_key, amount})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:poll_gauges, state) do
    snapshot = take_gauge_snapshot(state)
    snapshots = state.gauge_snapshots ++ [snapshot]

    timer = Process.send_after(self(), :poll_gauges, state.scenario.poll_interval_ms)
    {:noreply, %{state | gauge_snapshots: snapshots, poll_timer: timer}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Internal helpers --

  defp take_gauge_snapshot(state) do
    elapsed = System.monotonic_time(:millisecond) - state.start_time

    %{
      elapsed_ms: elapsed,
      memory_bytes: current_memory_bytes(),
      fd_count: current_fd_count(),
      process_count: :erlang.system_info(:process_count),
      scheduler_utilization: scheduler_utilization()
    }
  end

  defp current_memory_bytes do
    :erlang.memory(:total)
  end

  defp current_fd_count do
    # Try /proc/self/fd on Linux; fall back to :erlang.system_info
    case File.ls("/proc/self/fd") do
      {:ok, entries} -> length(entries)
      {:error, _} -> :erlang.system_info(:port_count)
    end
  end

  defp scheduler_utilization do
    # Return a simple snapshot of scheduler wall-clock utilization.
    # :scheduler_wall_time must be enabled for accurate results; if not,
    # we return 0.0 and the report treats it as unavailable.
    try do
      :erlang.statistics(:scheduler_wall_time_all)
      |> Enum.map(fn {_id, active, total} ->
        if total > 0, do: active / total, else: 0.0
      end)
      |> then(fn vals ->
        if vals == [], do: 0.0, else: Enum.sum(vals) / length(vals)
      end)
    catch
      _, _ -> 0.0
    end
  end

  defp read_all_latencies(table) do
    :ets.match(table, {{:latency, :"$1"}, :"$2"})
    |> Enum.map(fn [operation, samples] ->
      {operation, compute_percentiles(samples)}
    end)
    |> Map.new()
  end

  defp read_all_counters(table) do
    :ets.match(table, {{:counter, :"$1"}, :"$2"})
    |> Enum.map(fn [metric, value] -> {metric, value} end)
    |> Map.new()
  end

  @doc false
  def compute_percentiles([]), do: %{count: 0, min: 0, max: 0, mean: 0.0, p50: 0, p95: 0, p99: 0}

  def compute_percentiles(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    sum = Enum.sum(sorted)

    %{
      count: count,
      min: hd(sorted),
      max: List.last(sorted),
      mean: Float.round(sum / count, 2),
      p50: percentile_at(sorted, count, 0.50),
      p95: percentile_at(sorted, count, 0.95),
      p99: percentile_at(sorted, count, 0.99)
    }
  end

  defp percentile_at(sorted, count, p) do
    index = max(0, ceil(p * count) - 1)
    Enum.at(sorted, index, 0)
  end
end

# ---------------------------------------------------------------------------
# ConnectionSimulator
# ---------------------------------------------------------------------------

defmodule EchsCore.Observability.LoadTest.ConnectionSimulator do
  @moduledoc """
  Simulates concurrent WebSocket/SSE connections hitting the ECHS event pipeline.

  Each simulated connection runs as a Task under a TaskSupervisor and performs:
  - Connect (subscribe to a conversation)
  - Post messages at the configured turn interval
  - Randomly disconnect and reconnect based on `disconnect_probability`
  - Record latency for each operation via the MetricsCollector
  """

  use GenServer

  alias EchsCore.Observability.LoadTest.{MetricsCollector, Scenario}
  alias EchsCore.WebSocket.Handler

  require Logger

  defstruct [
    :scenario,
    :collector,
    :task_supervisor,
    :tasks,
    :completion_ref,
    :completed_count,
    :start_time
  ]

  @doc "Start the connection simulator."
  @spec start_link(Scenario.t(), MetricsCollector.t()) :: GenServer.on_start()
  def start_link(%Scenario{} = scenario, collector) do
    GenServer.start_link(__MODULE__, {scenario, collector})
  end

  @doc "Begin the simulation. Returns immediately; use `await_completion/2` to wait."
  @spec run(GenServer.server(), Scenario.t()) :: :ok
  def run(simulator, %Scenario{} = _scenario) do
    GenServer.call(simulator, :run)
  end

  @doc "Block until all simulated connections have finished."
  @spec await_completion(GenServer.server(), timeout()) :: :ok
  def await_completion(simulator, timeout \\ 60_000) do
    GenServer.call(simulator, :await_completion, timeout)
  end

  # -- GenServer callbacks --

  @impl true
  def init({scenario, collector}) do
    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %__MODULE__{
      scenario: scenario,
      collector: collector,
      task_supervisor: task_sup,
      tasks: [],
      completion_ref: nil,
      completed_count: 0,
      start_time: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    scenario = state.scenario
    start_time = System.monotonic_time(:millisecond)

    # Stagger connection starts across the ramp-up window
    ramp_delay_per =
      if scenario.connection_count > 0 do
        max(1, div(scenario.ramp_up_ms, scenario.connection_count))
      else
        0
      end

    parent = self()

    tasks =
      Enum.map(0..(scenario.connection_count - 1), fn index ->
        ramp_delay = index * ramp_delay_per

        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          if ramp_delay > 0, do: Process.sleep(ramp_delay)
          run_connection(index, scenario, state.collector, start_time)
          send(parent, {:connection_done, index})
        end)
      end)

    {:reply, :ok, %{state | tasks: tasks, start_time: start_time}}
  end

  @impl true
  def handle_call(:await_completion, from, state) do
    if state.completed_count >= state.scenario.connection_count do
      {:reply, :ok, state}
    else
      {:noreply, %{state | completion_ref: from}}
    end
  end

  @impl true
  def handle_info({:connection_done, _index}, state) do
    new_count = state.completed_count + 1
    state = %{state | completed_count: new_count}

    if new_count >= state.scenario.connection_count and state.completion_ref != nil do
      GenServer.reply(state.completion_ref, :ok)
      {:noreply, %{state | completion_ref: nil}}
    else
      {:noreply, state}
    end
  end

  # Handle Task exits (async_nolink sends {ref, result} and {:DOWN, ...})
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Connection lifecycle --

  defp run_connection(index, scenario, collector, global_start) do
    conversation_id = "loadtest_conv_#{index}"
    conn_state = connect(conversation_id, collector)

    MetricsCollector.increment(collector, :connections_established)

    run_connection_loop(conn_state, conversation_id, index, scenario, collector, global_start)
  end

  defp run_connection_loop(conn_state, conversation_id, index, scenario, collector, global_start) do
    elapsed = System.monotonic_time(:millisecond) - global_start

    if elapsed >= scenario.duration_ms do
      disconnect(conn_state, collector)
      :ok
    else
      # Maybe disconnect/reconnect
      {conn_state, conversation_id} =
        if :rand.uniform() < scenario.disconnect_probability do
          disconnect(conn_state, collector)
          MetricsCollector.increment(collector, :disconnections)

          Process.sleep(scenario.reconnect_delay_ms)

          new_conv_id = "loadtest_conv_#{index}_#{System.unique_integer([:positive])}"
          new_state = connect(new_conv_id, collector)
          MetricsCollector.increment(collector, :reconnections)

          {new_state, new_conv_id}
        else
          {conn_state, conversation_id}
        end

      # Post a message (simulated turn)
      conn_state = post_message(conn_state, conversation_id, scenario, collector)

      Process.sleep(scenario.turn_interval_ms)

      run_connection_loop(conn_state, conversation_id, index, scenario, collector, global_start)
    end
  end

  defp connect(conversation_id, collector) do
    t0 = System.monotonic_time(:microsecond)

    # Simulate a WebSocket connection using the Handler module directly
    send_fn = fn _data -> :ok end
    state = Handler.init(send_fn)

    subscribe_msg =
      Jason.encode!(%{
        "type" => "subscribe",
        "conversation_id" => conversation_id,
        "request_id" => "req_#{System.unique_integer([:positive])}"
      })

    {_result, state} =
      case Handler.handle_message(subscribe_msg, state) do
        {:ok, s} -> {:ok, s}
        {:error, _reason, s} -> {:error, s}
      end

    latency_us = System.monotonic_time(:microsecond) - t0
    MetricsCollector.record_latency(collector, :connect, latency_us / 1_000)

    state
  end

  defp disconnect(_conn_state, collector) do
    t0 = System.monotonic_time(:microsecond)
    # In a real scenario this would close the WebSocket.
    # The Handler is stateless from the server side, so we just discard.
    latency_us = System.monotonic_time(:microsecond) - t0
    MetricsCollector.record_latency(collector, :disconnect, latency_us / 1_000)
    :ok
  end

  defp post_message(conn_state, conversation_id, scenario, collector) do
    t0 = System.monotonic_time(:microsecond)

    content = generate_message(scenario.message_size_bytes)

    msg =
      Jason.encode!(%{
        "type" => "post_message",
        "conversation_id" => conversation_id,
        "content" => content,
        "request_id" => "req_#{System.unique_integer([:positive])}",
        "idempotency_key" => "idem_#{System.unique_integer([:positive])}"
      })

    new_state =
      case Handler.handle_message(msg, conn_state) do
        {:ok, s} ->
          MetricsCollector.increment(collector, :messages_sent)
          s

        {:error, _reason, s} ->
          MetricsCollector.increment(collector, :message_errors)
          s
      end

    latency_us = System.monotonic_time(:microsecond) - t0
    MetricsCollector.record_latency(collector, :post_message, latency_us / 1_000)

    new_state
  end

  defp generate_message(size_bytes) do
    # Generate a deterministic-ish message payload of the requested size.
    base = "load_test_payload_"
    # Use ceiling division to ensure we always generate enough bytes
    repeat_count = max(1, div(size_bytes + byte_size(base) - 1, byte_size(base)))
    String.duplicate(base, repeat_count) |> binary_part(0, size_bytes)
  end
end

# ---------------------------------------------------------------------------
# ReportGenerator
# ---------------------------------------------------------------------------

defmodule EchsCore.Observability.LoadTest.ReportGenerator do
  @moduledoc """
  Generates a text-based load test report with pass/fail thresholds.
  """

  alias EchsCore.Observability.LoadTest.Scenario

  @type check_result :: %{
          name: String.t(),
          status: :pass | :fail,
          value: term(),
          threshold: term(),
          message: String.t()
        }

  @type report :: %{
          scenario: Scenario.t(),
          metrics: map(),
          checks: [check_result()],
          passed: boolean(),
          summary_line: String.t(),
          formatted: String.t()
        }

  @doc "Build a complete report from scenario + metrics."
  @spec build(Scenario.t(), map()) :: report()
  def build(%Scenario{} = scenario, metrics) do
    checks = run_checks(scenario, metrics)
    all_passed = Enum.all?(checks, &(&1.status == :pass))

    pass_count = Enum.count(checks, &(&1.status == :pass))
    fail_count = Enum.count(checks, &(&1.status == :fail))

    summary_line =
      "#{scenario.name}: #{pass_count} passed, #{fail_count} failed " <>
        "(#{metrics.elapsed_ms}ms, #{scenario.connection_count} connections)"

    report = %{
      scenario: scenario,
      metrics: metrics,
      checks: checks,
      passed: all_passed,
      summary_line: summary_line,
      formatted: ""
    }

    %{report | formatted: format(report)}
  end

  @doc "Format a report as human-readable text."
  @spec format(report()) :: String.t()
  def format(report) do
    lines = [
      "=" |> String.duplicate(72),
      "  ECHS Load Test Report",
      "=" |> String.duplicate(72),
      "",
      "Scenario:     #{report.scenario.name}",
      "Connections:  #{report.scenario.connection_count}",
      "Duration:     #{report.metrics.elapsed_ms}ms",
      "",
      "--- Latency Percentiles ---",
      ""
    ]

    latency_lines =
      report.metrics.latencies
      |> Enum.sort_by(fn {op, _} -> op end)
      |> Enum.flat_map(fn {operation, stats} ->
        [
          "  #{operation}:",
          "    count=#{stats.count}  min=#{fmt_ms(stats.min)}  " <>
            "mean=#{fmt_ms(stats.mean)}  max=#{fmt_ms(stats.max)}",
          "    p50=#{fmt_ms(stats.p50)}  p95=#{fmt_ms(stats.p95)}  p99=#{fmt_ms(stats.p99)}",
          ""
        ]
      end)

    counter_lines = [
      "--- Counters ---",
      ""
    ]

    counter_detail =
      report.metrics.counters
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {metric, value} ->
        "  #{metric}: #{value}"
      end)

    system_lines = [
      "",
      "--- System ---",
      "",
      "  Memory baseline:  #{fmt_bytes(report.metrics.baseline_memory_bytes)}",
      "  Memory final:     #{fmt_bytes(report.metrics.final_memory_bytes)}",
      "  Memory growth:    #{fmt_bytes(report.metrics.memory_growth_bytes)}",
      "  FD baseline:      #{report.metrics.baseline_fds}",
      "  FD final:         #{report.metrics.final_fds}",
      ""
    ]

    gauge_lines =
      if report.metrics.gauge_snapshots != [] do
        last = List.last(report.metrics.gauge_snapshots)

        [
          "  Processes:        #{last.process_count}",
          "  Scheduler util:   #{Float.round(last.scheduler_utilization * 100, 1)}%",
          ""
        ]
      else
        []
      end

    check_header = [
      "--- Threshold Checks ---",
      ""
    ]

    check_lines =
      Enum.map(report.checks, fn c ->
        icon = if c.status == :pass, do: "[PASS]", else: "[FAIL]"
        "  #{icon} #{c.name}: #{c.message}"
      end)

    result_line = [
      "",
      "=" |> String.duplicate(72),
      if(report.passed, do: "  RESULT: ALL CHECKS PASSED", else: "  RESULT: CHECKS FAILED"),
      "=" |> String.duplicate(72),
      ""
    ]

    (lines ++
       latency_lines ++
       counter_lines ++
       counter_detail ++
       system_lines ++
       gauge_lines ++
       check_header ++
       check_lines ++
       result_line)
    |> Enum.join("\n")
  end

  # -- Threshold checks --

  defp run_checks(scenario, metrics) do
    thresholds = scenario.thresholds
    checks = []

    # p95 latency check (on post_message operation)
    checks =
      if Map.has_key?(thresholds, :p95_latency_ms) do
        post_latency = get_in(metrics, [:latencies, :post_message])
        p95 = if post_latency, do: post_latency.p95, else: 0
        threshold = thresholds.p95_latency_ms

        check = %{
          name: "p95_latency",
          status: if(p95 <= threshold, do: :pass, else: :fail),
          value: p95,
          threshold: threshold,
          message: "p95=#{fmt_ms(p95)} (threshold: #{fmt_ms(threshold)})"
        }

        [check | checks]
      else
        checks
      end

    # Memory growth check
    checks =
      if Map.has_key?(thresholds, :max_memory_growth_bytes) do
        growth = metrics.memory_growth_bytes
        threshold = thresholds.max_memory_growth_bytes

        check = %{
          name: "memory_growth",
          status: if(growth <= threshold, do: :pass, else: :fail),
          value: growth,
          threshold: threshold,
          message: "growth=#{fmt_bytes(growth)} (threshold: #{fmt_bytes(threshold)})"
        }

        [check | checks]
      else
        checks
      end

    # FD leak check: final FDs should not be wildly higher than baseline
    fd_growth = metrics.final_fds - metrics.baseline_fds
    fd_threshold = max(scenario.connection_count, 100)

    checks = [
      %{
        name: "fd_leak",
        status: if(fd_growth <= fd_threshold, do: :pass, else: :fail),
        value: fd_growth,
        threshold: fd_threshold,
        message: "fd_growth=#{fd_growth} (threshold: #{fd_threshold})"
      }
      | checks
    ]

    # Message throughput check (at least some messages should have been sent)
    messages_sent = Map.get(metrics.counters, :messages_sent, 0)

    checks = [
      %{
        name: "message_throughput",
        status: if(messages_sent > 0, do: :pass, else: :fail),
        value: messages_sent,
        threshold: 1,
        message: "#{messages_sent} messages sent"
      }
      | checks
    ]

    # Connection establishment check
    connections = Map.get(metrics.counters, :connections_established, 0)

    checks = [
      %{
        name: "connections_established",
        status: if(connections >= scenario.connection_count, do: :pass, else: :fail),
        value: connections,
        threshold: scenario.connection_count,
        message: "#{connections}/#{scenario.connection_count} connections established"
      }
      | checks
    ]

    Enum.reverse(checks)
  end

  defp fmt_ms(value) when is_float(value), do: "#{Float.round(value, 2)}ms"
  defp fmt_ms(value), do: "#{value}ms"

  defp fmt_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  defp fmt_bytes(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)}KB"
  defp fmt_bytes(bytes), do: "#{bytes}B"
end
