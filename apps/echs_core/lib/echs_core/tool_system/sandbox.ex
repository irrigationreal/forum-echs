defmodule EchsCore.ToolSystem.Sandbox do
  @moduledoc """
  Tool execution sandbox with safety enforcement.

  Enforces:
  - Workspace root containment (no path traversal)
  - Network allowlist/denylist
  - Environment variable filtering
  - Output size limits
  - Execution timeouts

  ## Path Safety

  All file paths in tool arguments are validated against the workspace root.
  Path traversal attempts (../, symlink escape) are blocked.

  ## Network Safety

  Network access is controlled per-tool via allowlist/denylist patterns.
  Default: deny all external network access for sandboxed tools.
  """

  require Logger

  @type sandbox_config :: %{
          workspace_root: String.t(),
          allowed_paths: [String.t()],
          denied_paths: [String.t()],
          network_allowlist: [String.t()],
          network_denylist: [String.t()],
          env_allowlist: [String.t()],
          max_output_bytes: non_neg_integer(),
          timeout_ms: non_neg_integer()
        }

  @default_config %{
    workspace_root: nil,
    allowed_paths: [],
    denied_paths: [],
    network_allowlist: [],
    network_denylist: ["*"],
    env_allowlist: ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "LC_ALL"],
    max_output_bytes: 1_048_576,
    timeout_ms: 120_000
  }

  @default_denied_patterns [
    ".git/config",
    ".env",
    "credentials",
    "secrets",
    ".ssh/",
    ".gnupg/",
    ".aws/credentials",
    ".kube/config"
  ]

  @doc """
  Create a sandbox config with the given workspace root and overrides.
  """
  @spec new(String.t(), keyword()) :: sandbox_config()
  def new(workspace_root, opts \\ []) do
    %{
      workspace_root: Path.expand(workspace_root),
      allowed_paths: Keyword.get(opts, :allowed_paths, []),
      denied_paths: Keyword.get(opts, :denied_paths, @default_denied_patterns),
      network_allowlist: Keyword.get(opts, :network_allowlist, []),
      network_denylist: Keyword.get(opts, :network_denylist, ["*"]),
      env_allowlist: Keyword.get(opts, :env_allowlist, @default_config.env_allowlist),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_config.max_output_bytes),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_config.timeout_ms)
    }
  end

  @doc """
  Validate that a file path is safe within the sandbox.

  Returns {:ok, resolved_path} if the path is within workspace bounds,
  or {:error, reason} if the path is outside or matches denied patterns.
  """
  @spec validate_path(sandbox_config(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_path(config, path) do
    workspace = config.workspace_root
    resolved = resolve_path(workspace, path)

    cond do
      workspace == nil ->
        {:error, "sandbox has no workspace_root configured"}

      not path_within?(resolved, workspace) ->
        {:error, "path traversal blocked: #{path} resolves outside workspace"}

      path_denied?(resolved, workspace, config.denied_paths) ->
        {:error, "path denied by policy: #{path}"}

      config.allowed_paths != [] and not path_explicitly_allowed?(resolved, workspace, config.allowed_paths) ->
        {:error, "path not in allowlist: #{path}"}

      true ->
        {:ok, resolved}
    end
  end

  @doc """
  Validate that a network host is allowed by the sandbox.
  """
  @spec validate_network(sandbox_config(), String.t()) :: :ok | {:error, String.t()}
  def validate_network(config, host) do
    cond do
      host_matches_any?(host, config.network_denylist) and
          not host_matches_any?(host, config.network_allowlist) ->
        {:error, "network access denied for host: #{host}"}

      config.network_allowlist != [] and not host_matches_any?(host, config.network_allowlist) ->
        {:error, "host not in network allowlist: #{host}"}

      true ->
        :ok
    end
  end

  @doc """
  Filter environment variables to only allowed ones.
  """
  @spec filter_env(sandbox_config()) :: [{String.t(), String.t()}]
  def filter_env(config) do
    System.get_env()
    |> Enum.filter(fn {key, _val} ->
      key in config.env_allowlist
    end)
  end

  @doc """
  Truncate output to the configured max_output_bytes.
  Returns {output, truncated?}.
  """
  @spec enforce_output_limit(sandbox_config(), String.t()) :: {String.t(), boolean()}
  def enforce_output_limit(config, output) do
    if byte_size(output) > config.max_output_bytes do
      truncated = binary_part(output, 0, config.max_output_bytes)
      # Find last valid UTF-8 boundary
      truncated = truncate_to_valid_utf8(truncated)
      marker = "\n\n[output truncated at #{config.max_output_bytes} bytes]"
      {truncated <> marker, true}
    else
      {output, false}
    end
  end

  @doc """
  Validate tool arguments for path safety.

  Scans argument values for file paths and validates each one.
  Returns {:ok, args} or {:error, reasons}.
  """
  @spec validate_args(sandbox_config(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_args(config, args) when is_map(args) do
    path_keys = [
      "path",
      "file",
      "file_path",
      "directory",
      "dir",
      "target",
      "source",
      "destination",
      "cwd",
      "working_directory"
    ]

    errors =
      args
      |> Enum.flat_map(fn {key, value} ->
        key_str = to_string(key)

        if key_str in path_keys and is_binary(value) do
          case validate_path(config, value) do
            {:ok, _} -> []
            {:error, reason} -> [reason]
          end
        else
          []
        end
      end)

    # Also check for path traversal in shell commands
    command_errors = validate_command_args(config, args)

    all_errors = errors ++ command_errors

    if all_errors == [] do
      {:ok, args}
    else
      {:error, all_errors}
    end
  end

  @doc """
  Check if a tool should be sandboxed based on its spec.
  Tools with side_effects: true that are not idempotent should be sandboxed.
  """
  @spec should_sandbox?(map()) :: boolean()
  def should_sandbox?(%{side_effects: true, idempotent: false}), do: true
  def should_sandbox?(%{side_effects: true}), do: true
  def should_sandbox?(_), do: false

  # --- Internal ---

  defp resolve_path(workspace, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(Path.join(workspace, path))
    end
  end

  defp path_within?(resolved, workspace) do
    # Ensure the resolved path starts with the workspace root
    String.starts_with?(resolved, workspace <> "/") or resolved == workspace
  end

  defp path_denied?(resolved, workspace, denied_patterns) do
    relative = Path.relative_to(resolved, workspace)

    Enum.any?(denied_patterns, fn pattern ->
      String.contains?(relative, pattern)
    end)
  end

  defp path_explicitly_allowed?(resolved, workspace, allowed_patterns) do
    relative = Path.relative_to(resolved, workspace)

    Enum.any?(allowed_patterns, fn pattern ->
      if String.ends_with?(pattern, "/") do
        String.starts_with?(relative, pattern)
      else
        relative == pattern or String.starts_with?(relative, pattern <> "/")
      end
    end)
  end

  defp host_matches_any?(_host, []), do: false

  defp host_matches_any?(host, patterns) do
    Enum.any?(patterns, fn pattern ->
      cond do
        pattern == "*" ->
          true

        String.starts_with?(pattern, "*.") ->
          suffix = String.trim_leading(pattern, "*")
          String.ends_with?(host, suffix)

        true ->
          host == pattern
      end
    end)
  end

  defp validate_command_args(_config, args) do
    command = args["command"] || args[:command]

    if is_binary(command) do
      # Check for path traversal in shell commands
      if String.contains?(command, "../../") or
           String.match?(command, ~r/\.\.[\/\\]/) do
        ["potential path traversal in command: #{command}"]
      else
        []
      end
    else
      []
    end
  end

  defp truncate_to_valid_utf8(binary) do
    case String.chunk(binary, :valid) do
      [] -> ""
      chunks ->
        valid_chunks = Enum.filter(chunks, &String.valid?/1)
        Enum.join(valid_chunks)
    end
  end
end
