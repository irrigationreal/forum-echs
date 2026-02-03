defmodule EchsServer.HealthCheck do
  @moduledoc """
  Component-level health check. Returns a map with individual component
  statuses and an overall healthy/degraded verdict.

  Checked components:
    - registry      — EchsCore.Registry process alive
    - pubsub        — EchsCore.PubSub supervisor alive
    - turn_limiter  — EchsCore.TurnLimiter responsive
    - store_repo    — EchsStore.Repo alive (if store enabled)
    - circuit_codex — circuit breaker state for :codex
    - circuit_claude — circuit breaker state for :claude

  Also reports active_threads and limiter_queue_depth gauges.
  """

  @check_timeout_ms 2_000

  @doc """
  Run all health checks. Returns `{status_code, body}` where
  status_code is 200 (healthy) or 503 (degraded).
  """
  def run do
    checks = %{
      registry: check_process(EchsCore.Registry),
      pubsub: check_process(EchsCore.PubSub),
      turn_limiter: check_turn_limiter(),
      store_repo: check_store_repo(),
      circuit_codex: check_circuit(:codex),
      circuit_claude: check_circuit(:claude)
    }

    active_threads = count_active_threads()
    queue_depth = limiter_queue_depth()

    all_ok =
      Enum.all?(checks, fn {_k, v} -> v == :ok end)

    status = if all_ok, do: 200, else: 503

    body = %{
      ok: all_ok,
      status: if(all_ok, do: "healthy", else: "degraded"),
      components:
        Map.new(checks, fn {k, v} ->
          {k, if(v == :ok, do: "ok", else: format_check_result(v))}
        end),
      active_threads: active_threads,
      queue_depth: queue_depth
    }

    {status, body}
  end

  # -- Individual checks ---------------------------------------------------

  defp check_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: {:error, "dead"}

      nil ->
        {:error, "not_registered"}
    end
  end

  defp check_turn_limiter do
    if process_alive?(EchsCore.TurnLimiter) do
      try do
        GenServer.call(EchsCore.TurnLimiter, :status, @check_timeout_ms)
        :ok
      catch
        :exit, _ -> {:error, "unresponsive"}
      end
    else
      {:error, "not_running"}
    end
  end

  defp check_store_repo do
    cond do
      not Code.ensure_loaded?(EchsStore) ->
        :ok

      not EchsStore.enabled?() ->
        :ok

      not process_alive?(EchsStore.Repo) ->
        {:error, "not_running"}

      true ->
        try do
          EchsStore.Repo.query!("SELECT 1")
          :ok
        rescue
          _ -> {:error, "query_failed"}
        catch
          :exit, _ -> {:error, "unresponsive"}
        end
    end
  end

  defp check_circuit(name) do
    try do
      case EchsCodex.CircuitBreaker.state(name) do
        :closed -> :ok
        :half_open -> :ok
        :open -> {:error, "open"}
      end
    rescue
      _ -> {:error, "unavailable"}
    end
  end

  defp count_active_threads do
    try do
      Registry.select(EchsCore.Registry, [{{:_, :_, :_}, [], [true]}])
      |> length()
    rescue
      _ -> 0
    end
  end

  defp limiter_queue_depth do
    try do
      case GenServer.call(EchsCore.TurnLimiter, :status, @check_timeout_ms) do
        %{queue_size: size} -> size
        _ -> 0
      end
    catch
      :exit, _ -> 0
    end
  end

  defp process_alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp format_check_result({:error, reason}), do: reason
  defp format_check_result(other), do: inspect(other)
end
