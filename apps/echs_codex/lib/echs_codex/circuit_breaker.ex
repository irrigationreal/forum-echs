defmodule EchsCodex.CircuitBreaker do
  @moduledoc """
  Circuit breaker for API calls. Tracks consecutive failures per named circuit
  and trips open when a threshold is exceeded.

  States:
    - :closed   — requests pass through, failures counted
    - :open     — requests rejected immediately until timeout expires
    - :half_open — one probe request allowed; success closes, failure re-opens

  Configuration (env vars):
    - ECHS_CIRCUIT_BREAKER_THRESHOLD   — consecutive failures to trip (default 5)
    - ECHS_CIRCUIT_BREAKER_TIMEOUT_MS  — ms to stay open before half-open (default 30 000)

  Circuit state is stored in ETS for lock-free reads on the hot path.
  State transitions go through the GenServer to avoid races.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @default_threshold 5
  @default_timeout_ms 30_000

  # -- Public API ----------------------------------------------------------

  @doc """
  Check whether a circuit allows requests.

  Returns `:ok` or `{:error, :circuit_open}`.
  """
  def check(circuit) do
    case lookup(circuit) do
      :closed ->
        :ok

      :half_open ->
        :ok

      :open ->
        # Check if timeout has elapsed — if so, transition to half_open
        case :ets.lookup(@table, {:opened_at, circuit}) do
          [{_, opened_at}] ->
            if System.monotonic_time(:millisecond) - opened_at >= timeout_ms() do
              GenServer.call(__MODULE__, {:transition_half_open, circuit})
            else
              {:error, :circuit_open}
            end

          _ ->
            {:error, :circuit_open}
        end
    end
  end

  @doc "Record a successful API call — resets the circuit to closed."
  def record_success(circuit) do
    GenServer.cast(__MODULE__, {:success, circuit})
  end

  @doc "Record a failed API call — may trip the circuit open."
  def record_failure(circuit) do
    GenServer.cast(__MODULE__, {:failure, circuit})
  end

  @doc "Return the current state of a circuit (for health checks)."
  def state(circuit) do
    lookup(circuit)
  end

  @doc "Return a summary of all known circuits."
  def summary do
    try do
      :ets.match(@table, {{:state, :"$1"}, :"$2"})
      |> Enum.map(fn [circuit, state] ->
        failures =
          case :ets.lookup(@table, {:failures, circuit}) do
            [{_, n}] -> n
            _ -> 0
          end

        %{circuit: circuit, state: state, consecutive_failures: failures}
      end)
    rescue
      ArgumentError -> []
    end
  end

  # -- GenServer ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:transition_half_open, circuit}, _from, state) do
    current = lookup(circuit)

    if current == :open do
      set_state(circuit, :half_open)
      Logger.info("Circuit breaker #{circuit}: open -> half_open")
      {:reply, :ok, state}
    else
      reply = if current == :closed, do: :ok, else: :ok
      {:reply, reply, state}
    end
  end

  @impl true
  def handle_cast({:success, circuit}, state) do
    current = lookup(circuit)

    if current != :closed do
      Logger.info("Circuit breaker #{circuit}: #{current} -> closed")
    end

    set_state(circuit, :closed)
    :ets.insert(@table, {{:failures, circuit}, 0})
    {:noreply, state}
  end

  def handle_cast({:failure, circuit}, state) do
    current = lookup(circuit)

    case current do
      :half_open ->
        # Probe failed — re-open
        set_state(circuit, :open)
        :ets.insert(@table, {{:opened_at, circuit}, System.monotonic_time(:millisecond)})
        Logger.warning("Circuit breaker #{circuit}: half_open -> open (probe failed)")

      :closed ->
        failures = increment_failures(circuit)

        if failures >= threshold() do
          set_state(circuit, :open)
          :ets.insert(@table, {{:opened_at, circuit}, System.monotonic_time(:millisecond)})
          Logger.warning("Circuit breaker #{circuit}: closed -> open (#{failures} consecutive failures)")
        end

      :open ->
        # Already open, just update opened_at to extend timeout
        :ets.insert(@table, {{:opened_at, circuit}, System.monotonic_time(:millisecond)})
    end

    {:noreply, state}
  end

  # -- Internal helpers -----------------------------------------------------

  defp lookup(circuit) do
    case :ets.lookup(@table, {:state, circuit}) do
      [{_, state}] -> state
      _ -> :closed
    end
  rescue
    ArgumentError -> :closed
  end

  defp set_state(circuit, new_state) do
    :ets.insert(@table, {{:state, circuit}, new_state})
  end

  defp increment_failures(circuit) do
    try do
      :ets.update_counter(@table, {:failures, circuit}, {2, 1})
    rescue
      ArgumentError ->
        :ets.insert(@table, {{:failures, circuit}, 1})
        1
    end
  end

  defp threshold do
    case System.get_env("ECHS_CIRCUIT_BREAKER_THRESHOLD") do
      nil ->
        @default_threshold

      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> @default_threshold
        end
    end
  end

  defp timeout_ms do
    case System.get_env("ECHS_CIRCUIT_BREAKER_TIMEOUT_MS") do
      nil ->
        @default_timeout_ms

      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> @default_timeout_ms
        end
    end
  end
end
