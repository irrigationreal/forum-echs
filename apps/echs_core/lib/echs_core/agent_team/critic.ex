defmodule EchsCore.AgentTeam.Critic do
  @moduledoc """
  Critic agent for the /review workflow.

  Examines tool outputs, diffs, and task results to produce
  structured critique with findings, severity, and suggested actions.
  """

  @type severity :: :error | :warning | :suggestion | :info
  @type finding_category :: :correctness | :security | :performance | :style | :completeness

  @type finding :: %{
          id: String.t(),
          severity: severity(),
          category: finding_category(),
          title: String.t(),
          description: String.t(),
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          suggested_fix: String.t() | nil
        }

  @type critique :: %{
          critique_id: String.t(),
          task_id: String.t() | nil,
          findings: [finding()],
          summary: String.t(),
          pass: boolean(),
          created_at_ms: non_neg_integer()
        }

  @doc "Create a new critique from a list of findings."
  @spec new_critique(keyword()) :: critique()
  def new_critique(opts \\ []) do
    findings = Keyword.get(opts, :findings, [])

    %{
      critique_id: generate_id(),
      task_id: Keyword.get(opts, :task_id),
      findings: findings,
      summary: generate_summary(findings),
      pass: all_pass?(findings),
      created_at_ms: System.system_time(:millisecond)
    }
  end

  @doc "Create a finding."
  @spec finding(severity(), finding_category(), String.t(), keyword()) :: finding()
  def finding(severity, category, title, opts \\ []) do
    %{
      id: "f_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      severity: severity,
      category: category,
      title: title,
      description: Keyword.get(opts, :description, ""),
      file: Keyword.get(opts, :file),
      line: Keyword.get(opts, :line),
      suggested_fix: Keyword.get(opts, :suggested_fix)
    }
  end

  @doc "Check if critique passes (no errors)."
  @spec all_pass?([finding()]) :: boolean()
  def all_pass?(findings) do
    not Enum.any?(findings, &(&1.severity == :error))
  end

  @doc "Count findings by severity."
  @spec severity_counts([finding()]) :: %{severity() => non_neg_integer()}
  def severity_counts(findings) do
    findings
    |> Enum.group_by(& &1.severity)
    |> Map.new(fn {sev, items} -> {sev, length(items)} end)
  end

  @doc "Filter findings by minimum severity."
  @spec filter_by_severity([finding()], severity()) :: [finding()]
  def filter_by_severity(findings, min_severity) do
    threshold = severity_rank(min_severity)
    Enum.filter(findings, fn f -> severity_rank(f.severity) >= threshold end)
  end

  @doc "Generate follow-up tasks from findings."
  @spec findings_to_tasks([finding()]) :: [map()]
  def findings_to_tasks(findings) do
    findings
    |> Enum.filter(&(&1.severity in [:error, :warning]))
    |> Enum.map(fn f ->
      %{
        title: "Fix: #{f.title}",
        description: f.description <> if(f.suggested_fix, do: "\n\nSuggested fix: #{f.suggested_fix}", else: ""),
        priority: if(f.severity == :error, do: :high, else: :medium),
        tags: [Atom.to_string(f.category), "auto-from-critique"]
      }
    end)
  end

  # --- Internal ---

  defp generate_summary(findings) do
    counts = severity_counts(findings)
    errors = Map.get(counts, :error, 0)
    warnings = Map.get(counts, :warning, 0)
    suggestions = Map.get(counts, :suggestion, 0)

    parts = []
    parts = if errors > 0, do: parts ++ ["#{errors} error(s)"], else: parts
    parts = if warnings > 0, do: parts ++ ["#{warnings} warning(s)"], else: parts
    parts = if suggestions > 0, do: parts ++ ["#{suggestions} suggestion(s)"], else: parts

    if parts == [] do
      "No issues found."
    else
      "Found: #{Enum.join(parts, ", ")}."
    end
  end

  defp severity_rank(:error), do: 4
  defp severity_rank(:warning), do: 3
  defp severity_rank(:suggestion), do: 2
  defp severity_rank(:info), do: 1

  defp generate_id, do: "crit_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
