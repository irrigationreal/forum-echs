defmodule EchsServer.Metrics do
  @moduledoc """
  Telemetry handler that accumulates counters and histograms in ETS.

  Attaches to `[:echs, ...]` telemetry events and exposes metrics via
  `summary/0` (map) or `prometheus_text/0` (Prometheus text format).

  Started as part of the EchsServer application supervisor.
  """

  use GenServer

  @name __MODULE__
  @table :echs_metrics

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Return a summary map of all current metrics."
  def summary do
    counters =
      :ets.select(@table, [{{:counter, :"$1"}, [], [{{:"$1", :"$0"}}]}])
      |> Enum.map(fn {key, {:counter, _}} ->
        {key, :ets.lookup_element(@table, {:counter, key}, 2)}
      end)
      |> Map.new()

    histograms =
      :ets.select(@table, [{{:hist, :"$1"}, [], [{{:"$1", :"$0"}}]}])
      |> Enum.map(fn {key, {:hist, _}} ->
        {key, :ets.lookup_element(@table, {:hist, key}, 2)}
      end)
      |> Enum.reduce(%{}, fn {key, samples}, acc ->
        stats = histogram_stats(samples)
        Map.put(acc, key, stats)
      end)

    gauges =
      :ets.select(@table, [{{:gauge, :"$1"}, [], [{{:"$1", :"$0"}}]}])
      |> Enum.map(fn {key, {:gauge, _}} ->
        {key, :ets.lookup_element(@table, {:gauge, key}, 2)}
      end)
      |> Map.new()

    %{counters: counters, histograms: histograms, gauges: gauges}
  rescue
    ArgumentError -> %{counters: %{}, histograms: %{}, gauges: %{}}
  end

  @doc "Return metrics in Prometheus text exposition format."
  def prometheus_text do
    data = summary()
    lines = []

    lines =
      Enum.reduce(data.counters, lines, fn {key, value}, acc ->
        name = prom_name(key)
        ["# TYPE #{name} counter\n#{name} #{value}\n" | acc]
      end)

    lines =
      Enum.reduce(data.histograms, lines, fn {key, stats}, acc ->
        name = prom_name(key)

        hist_lines = [
          "# TYPE #{name} summary\n",
          "#{name}_count #{stats.count}\n",
          "#{name}_sum #{stats.sum}\n"
        ]

        hist_lines =
          if stats.count > 0 do
            hist_lines ++
              [
                "#{name}{quantile=\"0.5\"} #{stats.p50}\n",
                "#{name}{quantile=\"0.9\"} #{stats.p90}\n",
                "#{name}{quantile=\"0.99\"} #{stats.p99}\n"
              ]
          else
            hist_lines
          end

        [Enum.join(hist_lines) | acc]
      end)

    lines =
      Enum.reduce(data.gauges, lines, fn {key, value}, acc ->
        name = prom_name(key)
        ["# TYPE #{name} gauge\n#{name} #{value}\n" | acc]
      end)

    Enum.reverse(lines) |> Enum.join("\n")
  end

  # -------------------------------------------------------------------
  # GenServer
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set])

    attach_handlers()

    {:ok, %{table: table}}
  end

  # -------------------------------------------------------------------
  # Telemetry handlers
  # -------------------------------------------------------------------

  defp attach_handlers do
    events = [
      [:echs, :turn, :start],
      [:echs, :turn, :stop],
      [:echs, :turn, :exception],
      [:echs, :tool, :start],
      [:echs, :tool, :stop],
      [:echs, :api, :request],
      [:echs, :limiter, :acquire],
      [:echs, :subagent, :spawn],
      [:echs, :subagent, :terminate]
    ]

    Enum.each(events, fn event ->
      handler_id = "echs_metrics_" <> Enum.join(Enum.map(event, &to_string/1), "_")
      :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, nil)
    end)
  end

  @doc false
  def handle_event([:echs, :turn, :start], _measurements, _metadata, _config) do
    increment_counter(:echs_turns_started)
  end

  def handle_event([:echs, :turn, :stop], %{duration_ms: duration_ms}, %{status: status}, _config) do
    increment_counter(:"echs_turns_completed_#{status}")
    append_histogram(:echs_turn_duration_ms, duration_ms)
  end

  def handle_event([:echs, :turn, :exception], %{duration_ms: duration_ms}, _metadata, _config) do
    increment_counter(:echs_turns_exception)
    append_histogram(:echs_turn_duration_ms, duration_ms)
  end

  def handle_event([:echs, :tool, :start], _measurements, _metadata, _config) do
    increment_counter(:echs_tool_calls_started)
  end

  def handle_event([:echs, :tool, :stop], %{duration_ms: duration_ms}, %{tool_name: tool_name}, _config) do
    increment_counter(:"echs_tool_calls_completed_#{tool_name}")
    append_histogram(:echs_tool_duration_ms, duration_ms)
    append_histogram(:"echs_tool_duration_ms_#{tool_name}", duration_ms)
  end

  def handle_event([:echs, :api, :request], %{duration_ms: duration_ms} = measurements, %{status: status}, _config) do
    increment_counter(:"echs_api_requests_#{status}")

    if measurements[:input_tokens] do
      increment_counter_by(:echs_api_input_tokens, measurements.input_tokens)
    end

    if measurements[:output_tokens] do
      increment_counter_by(:echs_api_output_tokens, measurements.output_tokens)
    end

    append_histogram(:echs_api_duration_ms, duration_ms)
  end

  def handle_event([:echs, :limiter, :acquire], %{queue_depth: depth}, %{result: result}, _config) do
    increment_counter(:"echs_limiter_acquire_#{result}")
    set_gauge(:echs_limiter_queue_depth, depth)
  end

  def handle_event([:echs, :subagent, :spawn], %{child_count: count}, _metadata, _config) do
    increment_counter(:echs_subagents_spawned)
    set_gauge(:echs_subagent_count, count)
  end

  def handle_event([:echs, :subagent, :terminate], %{child_count: count}, _metadata, _config) do
    increment_counter(:echs_subagents_terminated)
    set_gauge(:echs_subagent_count, count)
  end

  # -------------------------------------------------------------------
  # ETS helpers
  # -------------------------------------------------------------------

  defp increment_counter(key) do
    try do
      :ets.update_counter(@table, {:counter, key}, {2, 1})
    catch
      :error, :badarg ->
        :ets.insert(@table, {{:counter, key}, 1})
    end
  end

  defp increment_counter_by(key, amount) when is_integer(amount) do
    try do
      :ets.update_counter(@table, {:counter, key}, {2, amount})
    catch
      :error, :badarg ->
        :ets.insert(@table, {{:counter, key}, amount})
    end
  end

  defp increment_counter_by(_key, _amount), do: :ok

  defp set_gauge(key, value) when is_integer(value) do
    :ets.insert(@table, {{:gauge, key}, value})
  end

  defp set_gauge(_key, _value), do: :ok

  defp append_histogram(key, value) when is_number(value) do
    ets_key = {:hist, key}

    try do
      existing = :ets.lookup_element(@table, ets_key, 2)
      # Keep last 1000 samples for percentile calculations
      samples = if length(existing) >= 1000, do: tl(existing) ++ [value], else: existing ++ [value]
      :ets.insert(@table, {ets_key, samples})
    catch
      :error, :badarg ->
        :ets.insert(@table, {ets_key, [value]})
    end
  end

  defp append_histogram(_key, _value), do: :ok

  defp histogram_stats([]), do: %{count: 0, sum: 0, p50: 0, p90: 0, p99: 0}

  defp histogram_stats(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    sum = Enum.sum(sorted)

    %{
      count: count,
      sum: sum,
      p50: percentile(sorted, count, 0.5),
      p90: percentile(sorted, count, 0.9),
      p99: percentile(sorted, count, 0.99)
    }
  end

  defp percentile(sorted, count, p) do
    index = max(0, round(p * count) - 1)
    Enum.at(sorted, index, 0)
  end

  defp prom_name(key) when is_atom(key), do: Atom.to_string(key)
  defp prom_name(key), do: to_string(key)
end
