defmodule EchsCore.QuotaManager do
  @moduledoc """
  Per-tenant and per-conversation quota enforcement.

  Tracks and enforces budgets for:
  - Token usage per conversation
  - Tool call counts per conversation
  - Wall time per conversation
  - Provider-level rate limits (requests per window)
  - Provider-level concurrency limits

  All quota checks are atomic: `check_and_consume/3` either succeeds and
  decrements the budget, or returns `{:error, :quota_exceeded, detail}` without
  side effects.

  ## Tenant defaults

  Defaults can be configured via application env:

      config :echs_core, EchsCore.QuotaManager,
        default_token_budget: 500_000,
        default_tool_call_limit: 200,
        default_wall_time_ms: 600_000

  ## Audit logging

  Every quota event (creation, consumption, exhaustion, reset) is emitted via
  `:telemetry` under `[:echs, :quota, *]` and logged at `:info` level for
  audit trail purposes.
  """

  use GenServer

  require Logger

  @name __MODULE__

  # -------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------

  @type tenant_id :: String.t()
  @type conversation_id :: String.t()
  @type provider :: String.t()

  @type quota_kind :: :tokens | :tool_calls | :wall_time_ms
  @type consume_request :: {quota_kind(), pos_integer()}

  @type conversation_quota :: %{
          tenant_id: tenant_id(),
          tokens_remaining: non_neg_integer() | :unlimited,
          tokens_used: non_neg_integer(),
          tool_calls_remaining: non_neg_integer() | :unlimited,
          tool_calls_used: non_neg_integer(),
          wall_time_limit_ms: non_neg_integer() | :unlimited,
          started_at: integer()
        }

  @type provider_rate :: %{
          limit: pos_integer(),
          window_ms: pos_integer(),
          requests: [integer()],
          concurrency_limit: pos_integer() | :unlimited,
          active: non_neg_integer()
        }

  @type state :: %{
          conversations: %{optional(conversation_id()) => conversation_quota()},
          provider_rates: %{optional({tenant_id(), provider()}) => provider_rate()},
          monitors: %{optional(reference()) => {tenant_id(), provider()}}
        }

  # -------------------------------------------------------------------
  # Defaults
  # -------------------------------------------------------------------

  @default_token_budget 500_000
  @default_tool_call_limit 200
  @default_wall_time_ms 600_000

  @default_rate_limit 60
  @default_rate_window_ms 60_000
  @default_concurrency_limit :unlimited

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a conversation with quota budgets.

  Options:
  - `:tenant_id` - required, the owning tenant
  - `:token_budget` - max tokens (default from config)
  - `:tool_call_limit` - max tool calls (default from config)
  - `:wall_time_ms` - max wall time in ms (default from config)
  """
  @spec register_conversation(conversation_id(), keyword()) :: :ok
  def register_conversation(conversation_id, opts \\ []) do
    GenServer.call(@name, {:register_conversation, conversation_id, opts})
  end

  @doc """
  Atomically check and consume quota for a conversation.

  Returns `:ok` on success, `{:error, :quota_exceeded, reason}` if any
  requested budget would be exceeded.

  ## Example

      QuotaManager.check_and_consume("conv_123", [
        {:tokens, 1500},
        {:tool_calls, 1}
      ])
  """
  @spec check_and_consume(conversation_id(), [consume_request()]) ::
          :ok | {:error, :quota_exceeded, String.t()}
  def check_and_consume(conversation_id, requests) do
    GenServer.call(@name, {:check_and_consume, conversation_id, requests})
  end

  @doc """
  Get current quota status for a conversation.
  """
  @spec get_quota(conversation_id()) :: {:ok, conversation_quota()} | {:error, :not_found}
  def get_quota(conversation_id) do
    GenServer.call(@name, {:get_quota, conversation_id})
  end

  @doc """
  Remove a conversation's quota tracking.
  """
  @spec remove_conversation(conversation_id()) :: :ok
  def remove_conversation(conversation_id) do
    GenServer.call(@name, {:remove_conversation, conversation_id})
  end

  @doc """
  Configure provider-level rate limits for a tenant.

  Options:
  - `:limit` - max requests per window (default #{@default_rate_limit})
  - `:window_ms` - window duration in ms (default #{@default_rate_window_ms})
  - `:concurrency_limit` - max concurrent requests (default :unlimited)
  """
  @spec set_provider_rate_limit(tenant_id(), provider(), keyword()) :: :ok
  def set_provider_rate_limit(tenant_id, provider, opts \\ []) do
    GenServer.call(@name, {:set_provider_rate_limit, tenant_id, provider, opts})
  end

  @doc """
  Check whether a provider request is allowed under rate/concurrency limits.

  Returns `{:ok, ref}` where `ref` must be passed to `release_provider_slot/1`
  when the request completes. Returns `{:error, :rate_limited, detail}` if the
  request would exceed the limit.
  """
  @spec acquire_provider_slot(tenant_id(), provider()) ::
          {:ok, reference()} | {:error, :rate_limited, String.t()}
  def acquire_provider_slot(tenant_id, provider) do
    GenServer.call(@name, {:acquire_provider_slot, tenant_id, provider, self()})
  end

  @doc """
  Release a provider concurrency slot obtained via `acquire_provider_slot/2`.
  """
  @spec release_provider_slot(reference()) :: :ok
  def release_provider_slot(ref) when is_reference(ref) do
    GenServer.cast(@name, {:release_provider_slot, ref})
  end

  @doc """
  Reset quota for a conversation (e.g. after a billing top-up).
  """
  @spec reset_quota(conversation_id(), keyword()) :: :ok | {:error, :not_found}
  def reset_quota(conversation_id, opts \\ []) do
    GenServer.call(@name, {:reset_quota, conversation_id, opts})
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok,
     %{
       conversations: %{},
       provider_rates: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:register_conversation, conversation_id, opts}, _from, state) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    token_budget = Keyword.get(opts, :token_budget, default_token_budget())
    tool_call_limit = Keyword.get(opts, :tool_call_limit, default_tool_call_limit())
    wall_time_ms = Keyword.get(opts, :wall_time_ms, default_wall_time_ms())

    quota = %{
      tenant_id: tenant_id,
      tokens_remaining: token_budget,
      tokens_used: 0,
      tool_calls_remaining: tool_call_limit,
      tool_calls_used: 0,
      wall_time_limit_ms: wall_time_ms,
      started_at: System.monotonic_time(:millisecond)
    }

    state = put_in(state, [:conversations, conversation_id], quota)

    audit_log(:register, %{
      conversation_id: conversation_id,
      tenant_id: tenant_id,
      token_budget: token_budget,
      tool_call_limit: tool_call_limit,
      wall_time_ms: wall_time_ms
    })

    {:reply, :ok, state}
  end

  def handle_call({:check_and_consume, conversation_id, requests}, _from, state) do
    case Map.get(state.conversations, conversation_id) do
      nil ->
        {:reply, {:error, :quota_exceeded, "conversation not registered"}, state}

      quota ->
        case try_consume(quota, requests) do
          {:ok, updated_quota} ->
            state = put_in(state, [:conversations, conversation_id], updated_quota)

            audit_log(:consume, %{
              conversation_id: conversation_id,
              tenant_id: quota.tenant_id,
              requests: requests
            })

            {:reply, :ok, state}

          {:error, reason} ->
            audit_log(:exceeded, %{
              conversation_id: conversation_id,
              tenant_id: quota.tenant_id,
              reason: reason
            })

            {:reply, {:error, :quota_exceeded, reason}, state}
        end
    end
  end

  def handle_call({:get_quota, conversation_id}, _from, state) do
    case Map.get(state.conversations, conversation_id) do
      nil -> {:reply, {:error, :not_found}, state}
      quota -> {:reply, {:ok, enrich_with_elapsed(quota)}, state}
    end
  end

  def handle_call({:remove_conversation, conversation_id}, _from, state) do
    case Map.get(state.conversations, conversation_id) do
      nil ->
        :ok

      quota ->
        audit_log(:remove, %{
          conversation_id: conversation_id,
          tenant_id: quota.tenant_id,
          tokens_used: quota.tokens_used,
          tool_calls_used: quota.tool_calls_used
        })
    end

    state = update_in(state, [:conversations], &Map.delete(&1, conversation_id))
    {:reply, :ok, state}
  end

  def handle_call({:set_provider_rate_limit, tenant_id, provider, opts}, _from, state) do
    rate = %{
      limit: Keyword.get(opts, :limit, @default_rate_limit),
      window_ms: Keyword.get(opts, :window_ms, @default_rate_window_ms),
      requests: [],
      concurrency_limit: Keyword.get(opts, :concurrency_limit, @default_concurrency_limit),
      active: 0
    }

    key = {tenant_id, provider}
    state = put_in(state, [:provider_rates, key], rate)

    audit_log(:provider_rate_set, %{
      tenant_id: tenant_id,
      provider: provider,
      limit: rate.limit,
      window_ms: rate.window_ms,
      concurrency_limit: rate.concurrency_limit
    })

    {:reply, :ok, state}
  end

  def handle_call({:acquire_provider_slot, tenant_id, provider, caller_pid}, _from, state) do
    key = {tenant_id, provider}

    case Map.get(state.provider_rates, key) do
      nil ->
        # No rate limit configured -- allow
        ref = make_ref()
        {:reply, {:ok, ref}, state}

      rate ->
        now = System.monotonic_time(:millisecond)
        pruned_requests = prune_window(rate.requests, now, rate.window_ms)

        cond do
          length(pruned_requests) >= rate.limit ->
            audit_log(:rate_limited, %{
              tenant_id: tenant_id,
              provider: provider,
              reason: "rate limit exceeded"
            })

            {:reply,
             {:error, :rate_limited,
              "#{rate.limit} requests per #{rate.window_ms}ms exceeded for #{provider}"},
             put_in(state, [:provider_rates, key, :requests], pruned_requests)}

          rate.concurrency_limit != :unlimited and rate.active >= rate.concurrency_limit ->
            audit_log(:rate_limited, %{
              tenant_id: tenant_id,
              provider: provider,
              reason: "concurrency limit exceeded"
            })

            {:reply,
             {:error, :rate_limited,
              "concurrency limit #{rate.concurrency_limit} exceeded for #{provider}"},
             put_in(state, [:provider_rates, key, :requests], pruned_requests)}

          true ->
            ref = make_ref()
            mon = Process.monitor(caller_pid)

            updated_rate = %{
              rate
              | requests: [now | pruned_requests],
                active: rate.active + 1
            }

            state =
              state
              |> put_in([:provider_rates, key], updated_rate)
              |> put_in([:monitors, mon], {key, ref})

            {:reply, {:ok, ref}, state}
        end
    end
  end

  def handle_call({:reset_quota, conversation_id, opts}, _from, state) do
    case Map.get(state.conversations, conversation_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      quota ->
        token_budget = Keyword.get(opts, :token_budget, default_token_budget())
        tool_call_limit = Keyword.get(opts, :tool_call_limit, default_tool_call_limit())
        wall_time_ms = Keyword.get(opts, :wall_time_ms, default_wall_time_ms())

        updated = %{
          quota
          | tokens_remaining: token_budget,
            tokens_used: 0,
            tool_calls_remaining: tool_call_limit,
            tool_calls_used: 0,
            wall_time_limit_ms: wall_time_ms,
            started_at: System.monotonic_time(:millisecond)
        }

        state = put_in(state, [:conversations, conversation_id], updated)

        audit_log(:reset, %{
          conversation_id: conversation_id,
          tenant_id: quota.tenant_id,
          token_budget: token_budget,
          tool_call_limit: tool_call_limit,
          wall_time_ms: wall_time_ms
        })

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:release_provider_slot, ref}, state) do
    # We find the monitor entry by scanning -- there are few concurrent monitors
    case find_monitor_by_ref(state.monitors, ref) do
      {:ok, mon_ref, key} ->
        Process.demonitor(mon_ref, [:flush])
        state = release_provider_active(state, key, mon_ref)
        {:noreply, state}

      :not_found ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, mon_ref) do
      nil ->
        {:noreply, state}

      {key, _ref} ->
        Logger.warning(
          "quota_manager releasing provider slot for crashed process provider=#{inspect(key)}"
        )

        state = release_provider_active(state, key, mon_ref)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp try_consume(quota, requests) do
    Enum.reduce_while(requests, {:ok, quota}, fn request, {:ok, acc} ->
      case consume_one(acc, request) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp consume_one(quota, {:tokens, amount}) do
    case quota.tokens_remaining do
      :unlimited ->
        {:ok, %{quota | tokens_used: quota.tokens_used + amount}}

      remaining when remaining >= amount ->
        {:ok,
         %{
           quota
           | tokens_remaining: remaining - amount,
             tokens_used: quota.tokens_used + amount
         }}

      remaining ->
        {:error, "token budget exceeded: requested #{amount}, remaining #{remaining}"}
    end
  end

  defp consume_one(quota, {:tool_calls, amount}) do
    case quota.tool_calls_remaining do
      :unlimited ->
        {:ok, %{quota | tool_calls_used: quota.tool_calls_used + amount}}

      remaining when remaining >= amount ->
        {:ok,
         %{
           quota
           | tool_calls_remaining: remaining - amount,
             tool_calls_used: quota.tool_calls_used + amount
         }}

      remaining ->
        {:error, "tool call limit exceeded: requested #{amount}, remaining #{remaining}"}
    end
  end

  defp consume_one(quota, {:wall_time_ms, _amount}) do
    case quota.wall_time_limit_ms do
      :unlimited ->
        {:ok, quota}

      limit ->
        elapsed = System.monotonic_time(:millisecond) - quota.started_at

        if elapsed <= limit do
          {:ok, quota}
        else
          {:error, "wall time exceeded: elapsed #{elapsed}ms, limit #{limit}ms"}
        end
    end
  end

  defp enrich_with_elapsed(quota) do
    elapsed = System.monotonic_time(:millisecond) - quota.started_at
    Map.put(quota, :elapsed_ms, elapsed)
  end

  defp prune_window(timestamps, now, window_ms) do
    cutoff = now - window_ms
    Enum.filter(timestamps, fn ts -> ts > cutoff end)
  end

  defp release_provider_active(state, key, mon_ref) do
    state = update_in(state, [:monitors], &Map.delete(&1, mon_ref))

    case Map.get(state.provider_rates, key) do
      nil ->
        state

      rate ->
        put_in(state, [:provider_rates, key, :active], max(rate.active - 1, 0))
    end
  end

  defp find_monitor_by_ref(monitors, target_ref) do
    Enum.find_value(monitors, :not_found, fn {mon_ref, {key, ref}} ->
      if ref == target_ref, do: {:ok, mon_ref, key}
    end)
  end

  defp audit_log(action, metadata) do
    :telemetry.execute(
      [:echs, :quota, action],
      %{system_time: System.system_time(:millisecond)},
      metadata
    )

    Logger.info("quota_manager action=#{action} #{inspect(metadata)}")
  end

  defp default_token_budget do
    Application.get_env(:echs_core, __MODULE__, [])
    |> Keyword.get(:default_token_budget, @default_token_budget)
  end

  defp default_tool_call_limit do
    Application.get_env(:echs_core, __MODULE__, [])
    |> Keyword.get(:default_tool_call_limit, @default_tool_call_limit)
  end

  defp default_wall_time_ms do
    Application.get_env(:echs_core, __MODULE__, [])
    |> Keyword.get(:default_wall_time_ms, @default_wall_time_ms)
  end
end
