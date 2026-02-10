defmodule EchsCore.LoadTest do
  use ExUnit.Case, async: false

  alias EchsCore.Observability.LoadTest
  alias EchsCore.Observability.LoadTest.{
    ConnectionSimulator,
    MetricsCollector,
    ReportGenerator,
    Scenario
  }

  # =====================================================================
  # Scenario tests
  # =====================================================================

  describe "Scenario" do
    test "ci_small has reasonable defaults" do
      s = Scenario.ci_small()
      assert s.name == "ci_small"
      assert s.connection_count == 10
      assert s.duration_ms == 5_000
      assert s.disconnect_probability > 0
      assert s.thresholds.p95_latency_ms > 0
    end

    test "full_scale targets 1k connections" do
      s = Scenario.full_scale()
      assert s.connection_count == 1_000
      assert s.active_turns == 200
      assert s.duration_ms == 30 * 60 * 1_000
    end

    test "medium is between ci_small and full_scale" do
      s = Scenario.medium()
      assert s.connection_count == 100
      assert s.active_turns == 30
    end

    test "custom scenario with overrides" do
      s = %Scenario{
        name: "custom",
        connection_count: 25,
        active_turns: 8,
        duration_ms: 3_000,
        disconnect_probability: 0.0,
        turn_interval_ms: 50,
        thresholds: %{p95_latency_ms: 100, max_memory_growth_bytes: 10_000_000}
      }

      assert s.connection_count == 25
      assert s.disconnect_probability == 0.0
    end
  end

  # =====================================================================
  # MetricsCollector tests
  # =====================================================================

  describe "MetricsCollector" do
    setup do
      scenario = %Scenario{poll_interval_ms: 60_000, duration_ms: 5_000}
      {:ok, collector} = MetricsCollector.start_link(scenario)
      :ok = MetricsCollector.snapshot_baseline(collector)
      {:ok, collector: collector}
    end

    test "records and retrieves latency samples", %{collector: collector} do
      for i <- 1..100 do
        MetricsCollector.record_latency(collector, :connect, i * 1.0)
      end

      # Give casts time to process
      Process.sleep(50)

      metrics = MetricsCollector.finalize(collector)
      connect_stats = metrics.latencies[:connect]

      assert connect_stats.count == 100
      assert connect_stats.min == 1.0
      assert connect_stats.max == 100.0
      assert connect_stats.p50 > 0
      assert connect_stats.p95 > 0
      assert connect_stats.p99 > 0
      assert connect_stats.p50 <= connect_stats.p95
      assert connect_stats.p95 <= connect_stats.p99
    end

    test "increments counters", %{collector: collector} do
      MetricsCollector.increment(collector, :messages_sent)
      MetricsCollector.increment(collector, :messages_sent)
      MetricsCollector.increment(collector, :messages_sent)
      MetricsCollector.increment(collector, :errors)

      Process.sleep(50)
      metrics = MetricsCollector.finalize(collector)

      assert metrics.counters[:messages_sent] == 3
      assert metrics.counters[:errors] == 1
    end

    test "increment_by adds arbitrary amounts", %{collector: collector} do
      MetricsCollector.increment_by(collector, :bytes_sent, 1024)
      MetricsCollector.increment_by(collector, :bytes_sent, 2048)

      Process.sleep(50)
      metrics = MetricsCollector.finalize(collector)

      assert metrics.counters[:bytes_sent] == 3072
    end

    test "captures system metrics", %{collector: collector} do
      metrics = MetricsCollector.finalize(collector)

      assert metrics.baseline_memory_bytes > 0
      assert metrics.final_memory_bytes > 0
      assert metrics.baseline_fds > 0
      assert metrics.final_fds > 0
      assert is_integer(metrics.elapsed_ms)
    end

    test "compute_percentiles handles empty list" do
      result = MetricsCollector.compute_percentiles([])
      assert result.count == 0
      assert result.p50 == 0
    end

    test "compute_percentiles calculates correctly" do
      # 1..100 gives a uniform distribution
      samples = Enum.map(1..100, &(&1 * 1.0))
      result = MetricsCollector.compute_percentiles(samples)

      assert result.count == 100
      assert result.min == 1.0
      assert result.max == 100.0
      assert result.p50 == 50.0
      assert result.p95 == 95.0
      assert result.p99 == 99.0
    end
  end

  # =====================================================================
  # ConnectionSimulator tests
  # =====================================================================

  describe "ConnectionSimulator" do
    test "runs a minimal simulation to completion" do
      scenario = %Scenario{
        name: "micro_test",
        connection_count: 3,
        active_turns: 2,
        duration_ms: 1_000,
        disconnect_probability: 0.0,
        reconnect_delay_ms: 100,
        turn_interval_ms: 100,
        message_size_bytes: 64,
        ramp_up_ms: 100,
        poll_interval_ms: 60_000,
        thresholds: %{p95_latency_ms: 500, max_memory_growth_bytes: 50_000_000}
      }

      {:ok, collector} = MetricsCollector.start_link(scenario)
      :ok = MetricsCollector.snapshot_baseline(collector)

      {:ok, simulator} = ConnectionSimulator.start_link(scenario, collector)
      :ok = ConnectionSimulator.run(simulator, scenario)
      :ok = ConnectionSimulator.await_completion(simulator, 30_000)

      metrics = MetricsCollector.finalize(collector)

      assert metrics.counters[:connections_established] == 3
      assert metrics.counters[:messages_sent] > 0
      assert Map.has_key?(metrics.latencies, :connect)
      assert Map.has_key?(metrics.latencies, :post_message)

      GenServer.stop(simulator)
    end

    test "handles disconnect/reconnect cycles" do
      scenario = %Scenario{
        name: "disconnect_test",
        connection_count: 2,
        active_turns: 1,
        duration_ms: 800,
        disconnect_probability: 1.0,
        reconnect_delay_ms: 50,
        turn_interval_ms: 100,
        message_size_bytes: 32,
        ramp_up_ms: 0,
        poll_interval_ms: 60_000,
        thresholds: %{p95_latency_ms: 1000, max_memory_growth_bytes: 50_000_000}
      }

      {:ok, collector} = MetricsCollector.start_link(scenario)
      :ok = MetricsCollector.snapshot_baseline(collector)

      {:ok, simulator} = ConnectionSimulator.start_link(scenario, collector)
      :ok = ConnectionSimulator.run(simulator, scenario)
      :ok = ConnectionSimulator.await_completion(simulator, 30_000)

      metrics = MetricsCollector.finalize(collector)

      # With disconnect_probability=1.0 every loop iteration disconnects
      assert Map.get(metrics.counters, :disconnections, 0) > 0
      assert Map.get(metrics.counters, :reconnections, 0) > 0

      GenServer.stop(simulator)
    end
  end

  # =====================================================================
  # ReportGenerator tests
  # =====================================================================

  describe "ReportGenerator" do
    test "builds a passing report" do
      scenario = Scenario.ci_small()

      metrics = %{
        elapsed_ms: 5_000,
        latencies: %{
          connect: %{count: 100, min: 0.1, max: 5.0, mean: 1.0, p50: 0.8, p95: 3.0, p99: 4.5},
          post_message: %{count: 200, min: 0.5, max: 10.0, mean: 2.0, p50: 1.5, p95: 8.0, p99: 9.0}
        },
        counters: %{
          connections_established: 10,
          messages_sent: 200,
          disconnections: 5,
          reconnections: 5
        },
        baseline_memory_bytes: 50_000_000,
        final_memory_bytes: 55_000_000,
        memory_growth_bytes: 5_000_000,
        baseline_fds: 50,
        final_fds: 55,
        gauge_snapshots: [
          %{elapsed_ms: 0, memory_bytes: 50_000_000, fd_count: 50, process_count: 100, scheduler_utilization: 0.1},
          %{elapsed_ms: 5_000, memory_bytes: 55_000_000, fd_count: 55, process_count: 110, scheduler_utilization: 0.15}
        ]
      }

      report = ReportGenerator.build(scenario, metrics)

      assert report.passed
      assert report.summary_line =~ "ci_small"
      assert report.formatted =~ "ECHS Load Test Report"
      assert report.formatted =~ "[PASS]"
      assert report.formatted =~ "ALL CHECKS PASSED"
      assert report.formatted =~ "post_message"
      assert report.formatted =~ "p95="
    end

    test "builds a failing report when thresholds exceeded" do
      scenario = %Scenario{
        name: "fail_test",
        connection_count: 10,
        duration_ms: 5_000,
        thresholds: %{
          p95_latency_ms: 5,
          max_memory_growth_bytes: 100
        }
      }

      metrics = %{
        elapsed_ms: 5_000,
        latencies: %{
          post_message: %{count: 100, min: 1.0, max: 50.0, mean: 10.0, p50: 8.0, p95: 45.0, p99: 48.0}
        },
        counters: %{
          connections_established: 10,
          messages_sent: 100
        },
        baseline_memory_bytes: 50_000_000,
        final_memory_bytes: 60_000_000,
        memory_growth_bytes: 10_000_000,
        baseline_fds: 50,
        final_fds: 55,
        gauge_snapshots: []
      }

      report = ReportGenerator.build(scenario, metrics)

      refute report.passed
      assert report.formatted =~ "[FAIL]"
      assert report.formatted =~ "CHECKS FAILED"
    end

    test "report format includes all sections" do
      scenario = Scenario.ci_small()

      metrics = %{
        elapsed_ms: 1_000,
        latencies: %{
          connect: %{count: 10, min: 0.1, max: 1.0, mean: 0.5, p50: 0.5, p95: 0.9, p99: 1.0}
        },
        counters: %{connections_established: 10, messages_sent: 50},
        baseline_memory_bytes: 40_000_000,
        final_memory_bytes: 42_000_000,
        memory_growth_bytes: 2_000_000,
        baseline_fds: 30,
        final_fds: 32,
        gauge_snapshots: [
          %{elapsed_ms: 1_000, memory_bytes: 42_000_000, fd_count: 32, process_count: 80, scheduler_utilization: 0.05}
        ]
      }

      report = ReportGenerator.build(scenario, metrics)
      text = report.formatted

      assert text =~ "Latency Percentiles"
      assert text =~ "Counters"
      assert text =~ "System"
      assert text =~ "Threshold Checks"
      assert text =~ "Memory baseline"
      assert text =~ "Memory growth"
      assert text =~ "FD baseline"
      assert text =~ "Scheduler util"
    end
  end

  # =====================================================================
  # Integration: small end-to-end scenario
  # =====================================================================

  describe "end-to-end (ci_small)" do
    @tag timeout: 30_000
    test "runs ci_small scenario to completion" do
      scenario = %Scenario{
        name: "test_e2e",
        connection_count: 5,
        active_turns: 3,
        duration_ms: 2_000,
        disconnect_probability: 0.05,
        reconnect_delay_ms: 100,
        turn_interval_ms: 100,
        message_size_bytes: 64,
        ramp_up_ms: 200,
        poll_interval_ms: 500,
        thresholds: %{
          p95_latency_ms: 500,
          max_memory_growth_bytes: 100_000_000
        }
      }

      {:ok, report} = LoadTest.run(scenario)

      assert report.passed
      assert report.metrics.counters[:connections_established] == 5
      assert report.metrics.counters[:messages_sent] > 0
      assert report.metrics.elapsed_ms >= 2_000

      # Latency should be reasonable for in-process handler dispatch
      post_stats = report.metrics.latencies[:post_message]
      assert post_stats.p95 < 500
    end
  end
end
