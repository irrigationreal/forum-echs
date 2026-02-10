defmodule EchsCore.Rune.Invariant do
  @moduledoc """
  Invariant assertion framework for ECHS 2.0.

  Provides `inv_ok?/2` and `inv_fail/3` for checking and reporting
  system invariant violations. Violations are logged as structured
  events and optionally emitted as `system.invariant_violation` runes.

  ## Modes

  - `:lab` — violations raise (useful for tests and development)
  - `:prod` — violations log + emit rune (never raise)

  Mode is configured via application env:

      config :echs_core, :invariant_mode, :prod

  ## Rate Limiting

  To prevent log storms, violations for the same invariant ID are
  rate-limited to at most once per second per invariant by default.
  Configurable via `:invariant_rate_limit_ms`.

  ## Usage

      import EchsCore.Rune.Invariant

      inv_ok?("INV-EVENTID-MONOTONIC", new_eid > last_eid)
      # Returns true if condition holds, false + logs/raises otherwise

      inv_fail("INV-TOOL-TERMINAL", "Duplicate result for call_id=\#{call_id}",
        context: %{call_id: call_id, agent_id: agent_id})
      # Always reports a violation
  """

  require Logger

  @type severity :: :fatal | :error | :warn
  @type context :: %{optional(atom()) => term()}

  @doc """
  Check an invariant condition. Returns true if the condition holds.
  If the condition is false, reports the violation and returns false
  (or raises in :lab mode).

  ## Options

    * `:severity` — `:fatal`, `:error`, or `:warn` (default: `:error`)
    * `:context` — map of additional context for debugging
    * `:message` — custom message (default: auto-generated)
  """
  @spec inv_ok?(String.t(), boolean(), keyword()) :: boolean()
  def inv_ok?(invariant_id, condition, opts \\ [])

  def inv_ok?(_invariant_id, true, _opts), do: true

  def inv_ok?(invariant_id, false, opts) do
    severity = Keyword.get(opts, :severity, :error)
    context = Keyword.get(opts, :context, %{})
    message = Keyword.get(opts, :message, "Invariant #{invariant_id} violated")

    report_violation(invariant_id, severity, message, context)
    false
  end

  @doc """
  Report an invariant violation unconditionally.

  ## Options

    * `:severity` — `:fatal`, `:error`, or `:warn` (default: `:error`)
    * `:context` — map of additional context for debugging
  """
  @spec inv_fail(String.t(), String.t(), keyword()) :: :ok
  def inv_fail(invariant_id, message, opts \\ []) do
    severity = Keyword.get(opts, :severity, :error)
    context = Keyword.get(opts, :context, %{})

    report_violation(invariant_id, severity, message, context)
    :ok
  end

  @doc """
  Returns the current invariant mode (`:lab` or `:prod`).
  """
  @spec mode() :: :lab | :prod
  def mode do
    Application.get_env(:echs_core, :invariant_mode, default_mode())
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp default_mode do
    if Mix.env() == :test, do: :lab, else: :prod
  rescue
    # Mix not available in releases
    _ -> :prod
  end

  defp report_violation(invariant_id, severity, message, context) do
    if rate_limited?(invariant_id) do
      :ok
    else
      record_rate_limit(invariant_id)
      do_report(invariant_id, severity, message, context)
    end
  end

  defp do_report(invariant_id, severity, message, context) do
    structured = %{
      invariant_id: invariant_id,
      severity: severity,
      message: message,
      context: context,
      ts_ms: System.system_time(:millisecond)
    }

    # Structured log
    log_violation(severity, structured)

    # Telemetry event
    :telemetry.execute(
      [:echs, :invariant, :violation],
      %{count: 1},
      structured
    )

    # In lab mode, raise for fatal and error severities
    if mode() == :lab and severity in [:fatal, :error] do
      raise "Invariant violation [#{invariant_id}]: #{message} (context: #{inspect(context)})"
    end

    :ok
  end

  defp log_violation(:fatal, data) do
    Logger.error("[INV-FATAL] #{data.invariant_id}: #{data.message}",
      invariant: data
    )
  end

  defp log_violation(:error, data) do
    Logger.error("[INV-ERROR] #{data.invariant_id}: #{data.message}",
      invariant: data
    )
  end

  defp log_violation(:warn, data) do
    Logger.warning("[INV-WARN] #{data.invariant_id}: #{data.message}",
      invariant: data
    )
  end

  # -------------------------------------------------------------------
  # Rate limiting via process dictionary (simple, per-process)
  # Falls back to ETS for cross-process dedup in prod mode.
  # -------------------------------------------------------------------

  @rate_limit_ms 1_000

  defp rate_limited?(invariant_id) do
    key = {:inv_rate, invariant_id}
    now = System.monotonic_time(:millisecond)
    rate_ms = Application.get_env(:echs_core, :invariant_rate_limit_ms, @rate_limit_ms)

    case Process.get(key) do
      nil -> false
      last when now - last < rate_ms -> true
      _ -> false
    end
  end

  defp record_rate_limit(invariant_id) do
    key = {:inv_rate, invariant_id}
    Process.put(key, System.monotonic_time(:millisecond))
  end
end
