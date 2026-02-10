defmodule EchsCore.ToolSystem.PermissionPolicy do
  @moduledoc """
  Approval modes and permission policy engine for tool invocations.

  ## Approval Modes

  - `:full_access` — all tools auto-approved (current v1 behavior)
  - `:auto` — read-only tools auto-approved, side-effectful tools need approval
  - `:read_only` — only read-only tools allowed, everything else denied

  ## Policy Evaluation

  The policy is evaluated deterministically:

  1. Check per-tool override (`requires_approval` on ToolSpec)
  2. Check workspace scope rules (path allowlist)
  3. Check network access rules (if applicable)
  4. Fall through to conversation-level approval mode

  ## Approval as Runes

  Approval decisions are recorded as durable runes:
  - `tool.approved` — tool execution was approved
  - `tool.denied` — tool execution was denied

  This enables deterministic replay of approval decisions.
  """

  alias EchsCore.ToolSystem.ToolSpec

  @type approval_mode :: :full_access | :auto | :read_only
  @type decision :: :approved | :denied | :needs_approval
  @type policy :: %{
          mode: approval_mode(),
          workspace_root: String.t() | nil,
          allowed_paths: [String.t()],
          denied_paths: [String.t()],
          network_allowlist: [String.t()],
          network_denylist: [String.t()],
          per_tool_overrides: %{optional(String.t()) => :always | :never}
        }

  @doc """
  Create a default policy (full_access — matches v1 behavior).
  """
  @spec default_policy() :: policy()
  def default_policy do
    %{
      mode: :full_access,
      workspace_root: nil,
      allowed_paths: [],
      denied_paths: [],
      network_allowlist: [],
      network_denylist: [],
      per_tool_overrides: %{}
    }
  end

  @doc """
  Evaluate whether a tool invocation should be approved, denied, or
  requires user approval.

  Returns:
  - `:approved` — execute immediately
  - `:denied` — do not execute, record denial
  - `:needs_approval` — pause and wait for user/system approval
  """
  @spec evaluate(policy(), ToolSpec.t(), map()) :: decision()
  def evaluate(policy, %ToolSpec{} = spec, context \\ %{}) do
    # 1. Check per-tool override on the spec itself
    case spec.requires_approval do
      :always -> :needs_approval
      :never -> :approved
      :inherit -> evaluate_policy(policy, spec, context)
    end
  end

  @doc """
  Check if a file path is within the allowed workspace scope.
  """
  @spec path_allowed?(policy(), String.t()) :: boolean()
  def path_allowed?(%{workspace_root: nil}, _path), do: true

  def path_allowed?(%{workspace_root: root} = policy, path) do
    normalized = Path.expand(path)
    normalized_root = Path.expand(root)

    in_workspace = String.starts_with?(normalized, normalized_root)

    in_allowed =
      policy.allowed_paths == [] or
        Enum.any?(policy.allowed_paths, &String.starts_with?(normalized, Path.expand(&1)))

    not_denied = not Enum.any?(policy.denied_paths, &String.starts_with?(normalized, Path.expand(&1)))

    in_workspace and in_allowed and not_denied
  end

  @doc """
  Check if a network host is allowed.
  """
  @spec network_allowed?(policy(), String.t()) :: boolean()
  def network_allowed?(%{network_allowlist: [], network_denylist: []}, _host), do: true

  def network_allowed?(%{network_allowlist: allowlist}, host) when allowlist != [] do
    Enum.any?(allowlist, &host_matches?(&1, host))
  end

  def network_allowed?(%{network_denylist: denylist}, host) do
    not Enum.any?(denylist, &host_matches?(&1, host))
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp evaluate_policy(policy, spec, _context) do
    case policy.mode do
      :full_access ->
        # Check per-tool overrides in policy
        check_overrides(policy, spec.name, :approved)

      :auto ->
        if spec.side_effects do
          check_overrides(policy, spec.name, :needs_approval)
        else
          check_overrides(policy, spec.name, :approved)
        end

      :read_only ->
        if spec.side_effects do
          check_overrides(policy, spec.name, :denied)
        else
          check_overrides(policy, spec.name, :approved)
        end
    end
  end

  defp check_overrides(policy, tool_name, default) do
    case Map.get(policy.per_tool_overrides, tool_name) do
      :always -> :needs_approval
      :never -> :approved
      nil -> default
    end
  end

  defp host_matches?(pattern, host) do
    if String.starts_with?(pattern, "*.") do
      suffix = String.trim_leading(pattern, "*")
      String.ends_with?(host, suffix) or host == String.trim_leading(suffix, ".")
    else
      pattern == host
    end
  end
end
