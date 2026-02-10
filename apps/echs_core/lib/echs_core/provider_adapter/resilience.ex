defmodule EchsCore.ProviderAdapter.Resilience do
  @moduledoc """
  Provider call resilience layer: retries, rate limiting, circuit breaker, tracing.

  Wraps any `(-> result)` provider call with composable resilience policies:

  1. **Rate limiter** — per-provider token-bucket; rejects with `{:error, :rate_limited}`
     when the bucket is empty.
  2. **Circuit breaker** — delegates to `EchsCodex.CircuitBreaker`; rejects with
     `{:error, :circuit_open}` when the circuit is open.
  3. **Retry with exponential back-off** — retries retryable failures up to
     `max_retries` times with jitter. Budget-aware: skips retries when
     `budget_remaining_fn` returns `{:ok, n}` with `n <= 0`.
  4. **Tracing spans** — records every attempt (and its outcome) as a child span
     via `EchsCore.Observability.Tracing`.

  ## Quick start

      alias EchsCore.ProviderAdapter.Resilience

      Resilience.with_resilience(:openai, %{max_retries: 3}, fn ->
        MyAdapter.start_stream(opts)
      end)

  ## Configuration

  Defaults live in `@default_opts`; override per-call via the second argument.
  """

  require Logger

  alias EchsCore.Observability.Tracing

  # ── Default options ────────────────────────────────────────────────

  @default_opts %{
    # Retry policy
    max_retries: 3,
    base_delay_ms: 200,
    max_delay_ms: 10_000,
    jitter_factor: 0.25,

    # Budget awareness — pass a 0-arity fun returning {:ok, remaining} | :unlimited
    budget_remaining_fn: nil,

    # Rate limiter
    rate_limit: 60,
    rate_window_ms: 60_000,

    # Circuit breaker
    circuit_breaker_enabled: true,

    # Tracing
    tracing_enabled: true,
    parent_span: nil
  }

  # ── Types ──────────────────────────────────────────────────────────

  @type provider_name :: atom()

  @type opts :: %{
          optional(:max_retries) => non_neg_integer(),
          optional(:base_delay_ms) => pos_integer(),
          optional(:max_delay_ms) => pos_integer(),
          optional(:jitter_factor) => float(),
          optional(:budget_remaining_fn) => (-> {:ok, number()} | :unlimited) | nil,
          optional(:rate_limit) => pos_integer(),
          optional(:rate_window_ms) => pos_integer(),
          optional(:circuit_breaker_enabled) => boolean(),
          optional(:tracing_enabled) => boolean(),
          optional(:parent_span) => Tracing.span() | nil
        }

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Execute `fun` with full resilience wrapping for the given provider.

  Returns whatever `fun` returns on success, or `{:error, reason}` when
  all retries are exhausted / the call is rejected by rate limiter or
  circuit breaker.
  """
  @spec with_resilience(provider_name(), opts() | keyword(), (-> term())) :: term()
  def with_resilience(provider, user_opts \\ %{}, fun) when is_atom(provider) and is_function(fun, 0) do
    merged = merge_opts(user_opts)

    span =
      if merged.tracing_enabled do
        start_resilience_span(provider, merged)
      else
        nil
      end

    result = do_with_resilience(provider, merged, fun, _attempt = 0, span)

    if span do
      finish_span(span, result)
    end

    result
  end

  # ── Rate Limiter (token bucket in ETS) ─────────────────────────────

  @rate_table __MODULE__.RateTable

  @doc """
  Initialise the ETS table backing the rate limiter.

  Must be called once — typically from `EchsCore.Application`.
  Calling it more than once is a no-op.
  """
  @spec init_rate_table() :: :ok
  def init_rate_table do
    if :ets.whereis(@rate_table) == :undefined do
      :ets.new(@rate_table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Check (and consume one token from) the per-provider rate bucket.

  Returns `:ok` or `{:error, :rate_limited}`.
  """
  @spec check_rate(provider_name(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_rate(provider, limit, window_ms) do
    ensure_rate_table()
    now = System.monotonic_time(:millisecond)
    key = {:rate, provider}

    case :ets.lookup(@rate_table, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        if count < limit do
          :ets.insert(@rate_table, {key, count + 1, window_start})
          :ok
        else
          {:error, :rate_limited}
        end

      _ ->
        # Window expired or first call — start a fresh window
        :ets.insert(@rate_table, {key, 1, now})
        :ok
    end
  end

  @doc """
  Reset the rate-limiter bucket for a provider (useful in tests).
  """
  @spec reset_rate(provider_name()) :: :ok
  def reset_rate(provider) do
    ensure_rate_table()
    :ets.delete(@rate_table, {:rate, provider})
    :ok
  end

  # ── Circuit Breaker Helpers ────────────────────────────────────────

  @doc """
  Query the circuit breaker state for a provider.
  Delegates to `EchsCodex.CircuitBreaker.state/1`.
  """
  @spec circuit_state(provider_name()) :: :closed | :open | :half_open
  def circuit_state(provider) do
    EchsCodex.CircuitBreaker.state(provider)
  end

  @doc """
  Manually reset (close) a circuit.
  Records a synthetic success which moves the circuit to `:closed`.
  """
  @spec reset_circuit(provider_name()) :: :ok
  def reset_circuit(provider) do
    EchsCodex.CircuitBreaker.record_success(provider)
  end

  # ── Retry Policy Helpers ───────────────────────────────────────────

  @doc """
  Compute the delay (in ms) for the given attempt number, including jitter.
  """
  @spec backoff_delay(non_neg_integer(), pos_integer(), pos_integer(), float()) ::
          non_neg_integer()
  def backoff_delay(attempt, base_delay_ms, max_delay_ms, jitter_factor) do
    raw = min(base_delay_ms * Integer.pow(2, attempt), max_delay_ms)
    jitter_range = trunc(raw * jitter_factor)

    jitter =
      if jitter_range > 0 do
        :rand.uniform(jitter_range * 2 + 1) - jitter_range - 1
      else
        0
      end

    max(0, raw + jitter)
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp merge_opts(user_opts) when is_list(user_opts) do
    merge_opts(Map.new(user_opts))
  end

  defp merge_opts(user_opts) when is_map(user_opts) do
    Map.merge(@default_opts, user_opts)
  end

  # Core retry loop
  defp do_with_resilience(provider, opts, fun, attempt, span) do
    # 1. Rate limit gate
    case check_rate(provider, opts.rate_limit, opts.rate_window_ms) do
      {:error, :rate_limited} = err ->
        log_and_trace(span, attempt, :rate_limited, provider)
        err

      :ok ->
        # 2. Circuit breaker gate
        cb_result =
          if opts.circuit_breaker_enabled do
            EchsCodex.CircuitBreaker.check(provider)
          else
            :ok
          end

        case cb_result do
          {:error, :circuit_open} = err ->
            log_and_trace(span, attempt, :circuit_open, provider)
            err

          :ok ->
            # 3. Execute the actual call
            attempt_span = maybe_start_attempt_span(span, attempt, provider)

            result =
              try do
                fun.()
              rescue
                e ->
                  {:error, %{type: "exception", message: Exception.message(e), retryable: true}}
              catch
                kind, reason ->
                  {:error, %{type: "#{kind}", message: inspect(reason), retryable: true}}
              end

            maybe_end_attempt_span(attempt_span, result)

            case classify(result) do
              :success ->
                if opts.circuit_breaker_enabled do
                  EchsCodex.CircuitBreaker.record_success(provider)
                end

                result

              {:retryable, _reason} ->
                if opts.circuit_breaker_enabled do
                  EchsCodex.CircuitBreaker.record_failure(provider)
                end

                maybe_retry(provider, opts, fun, attempt, span, result)

              {:non_retryable, _reason} ->
                if opts.circuit_breaker_enabled do
                  EchsCodex.CircuitBreaker.record_failure(provider)
                end

                result
            end
        end
    end
  end

  defp maybe_retry(provider, opts, fun, attempt, span, last_result) do
    cond do
      attempt >= opts.max_retries ->
        Logger.warning(
          "[Resilience] #{provider}: max retries (#{opts.max_retries}) exhausted"
        )

        last_result

      budget_exhausted?(opts) ->
        Logger.warning("[Resilience] #{provider}: budget exhausted, skipping retry")
        last_result

      true ->
        delay =
          backoff_delay(
            attempt,
            opts.base_delay_ms,
            opts.max_delay_ms,
            opts.jitter_factor
          )

        Logger.info(
          "[Resilience] #{provider}: retry #{attempt + 1}/#{opts.max_retries} in #{delay}ms"
        )

        log_and_trace(span, attempt, {:retry, delay}, provider)
        Process.sleep(delay)

        do_with_resilience(provider, opts, fun, attempt + 1, span)
    end
  end

  # ── Result Classification ──────────────────────────────────────────

  defp classify({:ok, _}), do: :success

  defp classify({:error, %{retryable: true} = reason}), do: {:retryable, reason}

  defp classify({:error, %{retryable: false} = reason}), do: {:non_retryable, reason}

  # HTTP-status-based heuristic for errors that don't carry :retryable
  defp classify({:error, %{status: status} = reason}) when status in [429, 500, 502, 503, 504] do
    {:retryable, reason}
  end

  defp classify({:error, reason}), do: {:non_retryable, reason}

  # Anything that isn't {:ok, _} or {:error, _} is treated as success
  # (some callers return bare values).
  defp classify(_other), do: :success

  # ── Budget Awareness ───────────────────────────────────────────────

  defp budget_exhausted?(%{budget_remaining_fn: nil}), do: false

  defp budget_exhausted?(%{budget_remaining_fn: fun}) when is_function(fun, 0) do
    case fun.() do
      {:ok, remaining} when remaining <= 0 -> true
      _ -> false
    end
  end

  # ── Tracing Helpers ────────────────────────────────────────────────

  defp start_resilience_span(provider, opts) do
    meta = %{provider: provider, max_retries: opts.max_retries, rate_limit: opts.rate_limit}

    case opts.parent_span do
      nil -> Tracing.start_span("provider.resilience", meta)
      parent -> Tracing.start_child_span(parent, "provider.resilience", meta)
    end
  end

  defp maybe_start_attempt_span(nil, _attempt, _provider), do: nil

  defp maybe_start_attempt_span(parent_span, attempt, provider) do
    Tracing.start_child_span(parent_span, "provider.attempt", %{
      provider: provider,
      attempt: attempt
    })
  end

  defp maybe_end_attempt_span(nil, _result), do: :ok

  defp maybe_end_attempt_span(span, result) do
    status = if match?({:ok, _}, result), do: :ok, else: :error
    ended = Tracing.end_span(span, status)
    Tracing.emit_telemetry(ended)
    :ok
  end

  defp finish_span(span, result) do
    status = if match?({:error, _}, result), do: :error, else: :ok
    ended = Tracing.end_span(span, status)
    Tracing.emit_telemetry(ended)
    :ok
  end

  defp log_and_trace(nil, _attempt, _event_type, _provider), do: :ok

  defp log_and_trace(span, attempt, event_type, provider) do
    event_name =
      case event_type do
        :rate_limited -> "rate_limited"
        :circuit_open -> "circuit_open"
        {:retry, _} -> "retry"
        _ -> "event"
      end

    meta =
      case event_type do
        {:retry, delay} -> %{attempt: attempt, provider: provider, delay_ms: delay}
        _ -> %{attempt: attempt, provider: provider}
      end

    _updated = Tracing.add_event(span, event_name, meta)
    :ok
  end

  # ── ETS helpers ────────────────────────────────────────────────────

  defp ensure_rate_table do
    if :ets.whereis(@rate_table) == :undefined do
      init_rate_table()
    end

    :ok
  end
end
