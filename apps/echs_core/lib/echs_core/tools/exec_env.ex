defmodule EchsCore.Tools.ExecEnv do
  @moduledoc false

  @core_vars ~w(HOME LOGNAME PATH SHELL USER USERNAME TMPDIR TEMP TMP)a

  @default_policy %{
    inherit: :all,
    ignore_default_excludes: true,
    exclude: [],
    include_only: [],
    set: %{}
  }

  @unified_exec_env %{
    "NO_COLOR" => "1",
    "TERM" => "dumb",
    "LANG" => "C.UTF-8",
    "LC_CTYPE" => "C.UTF-8",
    "LC_ALL" => "C.UTF-8",
    "COLORTERM" => "",
    "PAGER" => "cat",
    "GIT_PAGER" => "cat",
    "GH_PAGER" => "cat",
    "CODEX_CI" => "1"
  }

  def default_policy do
    @default_policy
  end

  def create_env(policy \\ nil) do
    policy = normalize_policy(policy || policy_from_config())
    populate_env(System.get_env(), policy)
  end

  def apply_unified_exec_env(env) when is_map(env) do
    Map.merge(env, @unified_exec_env)
  end

  defp policy_from_config do
    Application.get_env(:echs_core, :shell_environment_policy, @default_policy)
  end

  defp normalize_policy(policy) when is_map(policy) do
    %{
      inherit: normalize_inherit(Map.get(policy, :inherit) || Map.get(policy, "inherit")),
      ignore_default_excludes:
        Map.get(policy, :ignore_default_excludes, Map.get(policy, "ignore_default_excludes", true)),
      exclude: normalize_patterns(Map.get(policy, :exclude) || Map.get(policy, "exclude")),
      include_only:
        normalize_patterns(Map.get(policy, :include_only) || Map.get(policy, "include_only")),
      set: normalize_set(Map.get(policy, :set) || Map.get(policy, "set"))
    }
  end

  defp normalize_policy(_), do: @default_policy

  defp normalize_inherit(nil), do: :all
  defp normalize_inherit(:all), do: :all
  defp normalize_inherit(:none), do: :none
  defp normalize_inherit(:core), do: :core

  defp normalize_inherit(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "all" -> :all
      "none" -> :none
      "core" -> :core
      _ -> :all
    end
  end

  defp normalize_inherit(_), do: :all

  defp normalize_patterns(nil), do: []
  defp normalize_patterns(patterns) when is_list(patterns), do: Enum.map(patterns, &to_string/1)
  defp normalize_patterns(patterns), do: [to_string(patterns)]

  defp normalize_set(nil), do: %{}

  defp normalize_set(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_set(list) when is_list(list) do
    Map.new(list, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_set(_), do: %{}

  defp populate_env(vars, policy) when is_map(vars) do
    env =
      case policy.inherit do
        :all -> vars
        :none -> %{}
        :core ->
          core = MapSet.new(Enum.map(@core_vars, &String.downcase/1))

          Enum.reduce(vars, %{}, fn {key, value}, acc ->
            if MapSet.member?(core, String.downcase(key)) do
              Map.put(acc, key, value)
            else
              acc
            end
          end)
      end

    env =
      if policy.ignore_default_excludes do
        env
      else
        default_excludes = ["*KEY*", "*SECRET*", "*TOKEN*"]
        filter_env(env, default_excludes)
      end

    env = filter_env(env, policy.exclude)
    env = Map.merge(env, policy.set)

    if policy.include_only == [] do
      env
    else
      env
      |> Enum.filter(fn {key, _} -> matches_any?(key, policy.include_only) end)
      |> Map.new()
    end
  end

  defp filter_env(env, patterns) do
    if patterns == [] do
      env
    else
      env
      |> Enum.reject(fn {key, _} -> matches_any?(key, patterns) end)
      |> Map.new()
    end
  end

  defp matches_any?(_name, []), do: false

  defp matches_any?(name, patterns) do
    Enum.any?(patterns, &pattern_match?(name, &1))
  end

  defp pattern_match?(name, pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")
      |> then(&"^" <> &1 <> "$")
      |> Regex.compile!("i")

    Regex.match?(regex, name)
  end
end
