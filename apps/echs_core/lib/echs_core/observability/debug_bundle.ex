defmodule EchsCore.Observability.DebugBundle do
  @moduledoc """
  Deterministic debug bundle generator for ECHS conversations.

  Exports a self-contained, hermetic debug bundle containing:
  - Runelog segments (runes filtered by conversation_id)
  - Snapshots (latest derived state)
  - Sanitized tool transcripts (secrets redacted, large outputs truncated)
  - Provider metadata (model, token usage)
  - System info (ECHS version, Elixir/OTP versions, config)

  All sensitive data (API keys, tokens, passwords) is redacted before
  export. Bundle size is bounded by a configurable maximum.

  ## Usage

      {:ok, bundle} = DebugBundle.generate("conv_123",
        segment_dir: "/data/runelogs",
        snapshot_dir: "/data/snapshots"
      )

      # Write as JSON
      {:ok, path} = DebugBundle.write_json(bundle, "/tmp/debug_conv_123.json")

      # Write as tarball
      {:ok, path} = DebugBundle.write_tarball(bundle, "/tmp/debug_conv_123.tar.gz")

      # Get a text summary
      summary = DebugBundle.summarize(bundle)

  ## Replay

  Bundles include enough information for hermetic replay when loaded
  back via `from_json/1`.
  """

  alias EchsCore.Rune.{Schema, RunelogReader, Snapshot}

  @bundle_version 1
  @default_max_bytes 10 * 1024 * 1024
  @default_max_tool_output_bytes 8_192
  @default_max_runes 10_000

  # Patterns for secret redaction. Each regex is applied to string values
  # found in maps and lists during recursive traversal.
  @secret_patterns [
    # API keys with common prefixes (e.g. sk-proj-abc123..., api-key-xyz...)
    ~r/(?:sk|pk|api|key|token|secret|bearer|auth)[-_][A-Za-z0-9][-A-Za-z0-9_]{16,}/i,
    # AWS-style keys
    ~r/AKIA[0-9A-Z]{16}/,
    # Generic hex tokens (32+ chars)
    ~r/\b[0-9a-fA-F]{32,}\b/,
    # JWT tokens
    ~r/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/,
    # Base64-encoded secrets (long runs)
    ~r/(?:password|passwd|pwd|secret|token|apikey|api_key)\s*[:=]\s*\S+/i
  ]

  # Keys whose values should always be fully redacted
  @sensitive_keys MapSet.new([
    "api_key",
    "apikey",
    "api_secret",
    "secret",
    "secret_key",
    "password",
    "passwd",
    "token",
    "access_token",
    "refresh_token",
    "bearer_token",
    "authorization",
    "auth_token",
    "private_key",
    "client_secret",
    "signing_key",
    "encryption_key"
  ])

  @type bundle :: %{
          version: pos_integer(),
          conversation_id: String.t(),
          generated_at: non_neg_integer(),
          system_info: map(),
          runes: [map()],
          snapshot: map() | nil,
          provider_metadata: map(),
          stats: map()
        }

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Generate a debug bundle for a conversation.

  ## Options

    * `:segment_dir` — directory containing runelog segments (required)
    * `:snapshot_dir` — directory containing snapshots (optional)
    * `:max_bytes` — maximum bundle size in bytes (default: 10 MiB)
    * `:max_tool_output_bytes` — max size per tool output (default: 8 KiB)
    * `:max_runes` — maximum number of runes to include (default: 10_000)
    * `:redact` — whether to redact secrets (default: true)
    * `:include_snapshot` — whether to include snapshot data (default: true)
  """
  @spec generate(String.t(), keyword()) :: {:ok, bundle()} | {:error, term()}
  def generate(conversation_id, opts \\ []) do
    segment_dir = Keyword.fetch!(opts, :segment_dir)
    snapshot_dir = Keyword.get(opts, :snapshot_dir)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    max_tool_output = Keyword.get(opts, :max_tool_output_bytes, @default_max_tool_output_bytes)
    max_runes = Keyword.get(opts, :max_runes, @default_max_runes)
    should_redact = Keyword.get(opts, :redact, true)
    include_snapshot = Keyword.get(opts, :include_snapshot, true)

    with {:ok, runes} <- collect_runes(conversation_id, segment_dir, max_runes),
         sanitized_runes <- sanitize_runes(runes, max_tool_output),
         snapshot_data <- maybe_load_snapshot(conversation_id, snapshot_dir, include_snapshot),
         provider_meta <- extract_provider_metadata(runes),
         sys_info <- collect_system_info() do
      bundle = %{
        version: @bundle_version,
        conversation_id: conversation_id,
        generated_at: System.system_time(:millisecond),
        system_info: sys_info,
        runes: sanitized_runes,
        snapshot: snapshot_data,
        provider_metadata: provider_meta,
        stats: compute_stats(runes, sanitized_runes)
      }

      bundle =
        if should_redact do
          redact_secrets(bundle)
        else
          bundle
        end

      bundle = enforce_size_limit(bundle, max_bytes)

      {:ok, bundle}
    end
  end

  @doc """
  Redact sensitive data from any term (map, list, or string).

  Scans recursively through maps and lists, replacing values that match
  known secret patterns with `"[REDACTED]"`. Keys in `@sensitive_keys`
  have their values fully replaced.

  ## Examples

      iex> DebugBundle.redact_secrets(%{"api_key" => "sk-abc123", "data" => "safe"})
      %{"api_key" => "[REDACTED]", "data" => "safe"}

      iex> DebugBundle.redact_secrets("Authorization: Bearer sk-abc123xyz456789012345")
      "Authorization: Bearer [REDACTED]"
  """
  @spec redact_secrets(term()) :: term()
  def redact_secrets(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      key_str = to_string(k)

      if MapSet.member?(@sensitive_keys, String.downcase(key_str)) do
        {k, "[REDACTED]"}
      else
        {k, redact_secrets(v)}
      end
    end)
  end

  def redact_secrets(value) when is_list(value) do
    Enum.map(value, &redact_secrets/1)
  end

  def redact_secrets(value) when is_binary(value) do
    redact_string(value)
  end

  def redact_secrets(value), do: value

  @doc """
  Generate a human-readable text summary from a bundle.
  """
  @spec summarize(bundle()) :: String.t()
  def summarize(bundle) do
    rune_count = length(Map.get(bundle, :runes, []))
    has_snapshot = bundle[:snapshot] != nil

    kinds =
      bundle
      |> Map.get(:runes, [])
      |> Enum.frequencies_by(&Map.get(&1, "kind", "unknown"))

    provider = bundle[:provider_metadata] || %{}
    stats = bundle[:stats] || %{}
    sys = bundle[:system_info] || %{}

    lines = [
      "Debug Bundle: #{bundle[:conversation_id]}",
      "Generated: #{format_timestamp(bundle[:generated_at])}",
      "Bundle version: #{bundle[:version]}",
      "",
      "System:",
      "  ECHS version: #{sys["echs_version"] || "unknown"}",
      "  Elixir: #{sys["elixir_version"] || "unknown"}",
      "  OTP: #{sys["otp_version"] || "unknown"}",
      "",
      "Runes: #{rune_count} total",
      "  Kinds: #{format_kind_counts(kinds)}",
      "  Snapshot included: #{has_snapshot}",
      "",
      "Provider:",
      "  Model: #{provider["model"] || "unknown"}",
      "  Total input tokens: #{provider["total_input_tokens"] || 0}",
      "  Total output tokens: #{provider["total_output_tokens"] || 0}",
      "  Turn count: #{provider["turn_count"] || 0}",
      "",
      "Stats:",
      "  Original rune count: #{stats["original_rune_count"] || rune_count}",
      "  Tool calls: #{stats["tool_call_count"] || 0}",
      "  Errors: #{stats["error_count"] || 0}",
      "  Time span: #{format_time_span(stats["first_ts_ms"], stats["last_ts_ms"])}"
    ]

    Enum.join(lines, "\n")
  end

  @doc """
  Write a bundle as a JSON file.
  """
  @spec write_json(bundle(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_json(bundle, path) do
    json = Jason.encode!(bundle, pretty: true)

    case File.write(path, json) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write a bundle as a gzipped tarball containing the JSON bundle
  plus the summary as a separate text file.
  """
  @spec write_tarball(bundle(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_tarball(bundle, path) do
    json_data = Jason.encode!(bundle, pretty: true)
    summary_data = summarize(bundle)

    json_name = ~c"bundle.json"
    summary_name = ~c"summary.txt"

    files = [
      {json_name, json_data},
      {summary_name, summary_data}
    ]

    case :erl_tar.create(path, files, [:compressed]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load a bundle from a JSON file. Useful for hermetic replay.
  """
  @spec from_json(String.t()) :: {:ok, bundle()} | {:error, term()}
  def from_json(path) do
    with {:ok, data} <- File.read(path),
         {:ok, decoded} <- Jason.decode(data) do
      {:ok, decoded}
    end
  end

  @doc """
  Load a bundle from a gzipped tarball.
  """
  @spec from_tarball(String.t()) :: {:ok, bundle()} | {:error, term()}
  def from_tarball(path) do
    case :erl_tar.extract(path, [:compressed, :memory]) do
      {:ok, files} ->
        case List.keyfind(files, ~c"bundle.json", 0) do
          {_name, json_data} ->
            case Jason.decode(json_data) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, reason} -> {:error, {:decode_error, reason}}
            end

          nil ->
            {:error, :bundle_json_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Rune collection
  # -------------------------------------------------------------------

  @spec collect_runes(String.t(), String.t(), non_neg_integer()) ::
          {:ok, [Schema.t()]} | {:error, term()}
  defp collect_runes(conversation_id, segment_dir, max_runes) do
    segments = list_segments(segment_dir, conversation_id)

    runes =
      segments
      |> Enum.flat_map(fn path ->
        case RunelogReader.open(path, load_index: false) do
          {:ok, reader} ->
            {runes, _} = RunelogReader.read_all(reader)
            RunelogReader.close(reader)
            runes

          {:error, _} ->
            []
        end
      end)
      |> Enum.filter(&(&1.conversation_id == conversation_id))
      |> Enum.sort_by(& &1.event_id)
      |> Enum.take(max_runes)

    {:ok, runes}
  end

  defp list_segments(dir, conversation_id) do
    prefix = "#{conversation_id}_"

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".seg")))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  # -------------------------------------------------------------------
  # Sanitization
  # -------------------------------------------------------------------

  defp sanitize_runes(runes, max_tool_output) do
    Enum.map(runes, fn rune ->
      encoded = Schema.encode(rune)
      sanitize_tool_output(encoded, max_tool_output)
    end)
  end

  defp sanitize_tool_output(encoded_rune, max_tool_output) do
    case encoded_rune["kind"] do
      "tool.result" ->
        update_in(encoded_rune, ["payload"], fn payload ->
          truncate_payload_output(payload, max_tool_output)
        end)

      "tool.call" ->
        update_in(encoded_rune, ["payload"], fn payload ->
          truncate_payload_arguments(payload, max_tool_output)
        end)

      _ ->
        encoded_rune
    end
  end

  defp truncate_payload_output(nil, _max), do: nil

  defp truncate_payload_output(payload, max) when is_map(payload) do
    case Map.get(payload, "output") do
      output when is_binary(output) and byte_size(output) > max ->
        truncated = binary_part(output, 0, max)

        Map.merge(payload, %{
          "output" => truncated <> "\n... [truncated #{byte_size(output) - max} bytes]",
          "_truncated" => true,
          "_original_bytes" => byte_size(output)
        })

      _ ->
        payload
    end
  end

  defp truncate_payload_output(payload, _max), do: payload

  defp truncate_payload_arguments(nil, _max), do: nil

  defp truncate_payload_arguments(payload, max) when is_map(payload) do
    case Map.get(payload, "arguments") do
      args when is_binary(args) and byte_size(args) > max ->
        truncated = binary_part(args, 0, max)

        Map.merge(payload, %{
          "arguments" => truncated <> "\n... [truncated #{byte_size(args) - max} bytes]",
          "_truncated" => true,
          "_original_bytes" => byte_size(args)
        })

      _ ->
        payload
    end
  end

  defp truncate_payload_arguments(payload, _max), do: payload

  # -------------------------------------------------------------------
  # Snapshot loading
  # -------------------------------------------------------------------

  defp maybe_load_snapshot(_conversation_id, nil, _include), do: nil
  defp maybe_load_snapshot(_conversation_id, _dir, false), do: nil

  defp maybe_load_snapshot(conversation_id, snapshot_dir, true) do
    case Snapshot.latest(snapshot_dir, conversation_id) do
      {:ok, event_id, path} ->
        case Snapshot.read(path) do
          {:ok, ^event_id, state} ->
            %{
              "event_id" => event_id,
              "state" => state
            }

          _ ->
            nil
        end

      :none ->
        nil
    end
  end

  # -------------------------------------------------------------------
  # Provider metadata extraction
  # -------------------------------------------------------------------

  defp extract_provider_metadata(runes) do
    # Extract usage info from usage runes and model info from turn runes
    usage_runes =
      Enum.filter(runes, fn r -> r.kind in ["turn.usage", "provider.usage"] end)

    total_input =
      Enum.reduce(usage_runes, 0, fn r, acc ->
        acc + (get_in(r.payload, ["input_tokens"]) || 0)
      end)

    total_output =
      Enum.reduce(usage_runes, 0, fn r, acc ->
        acc + (get_in(r.payload, ["output_tokens"]) || 0)
      end)

    # Try to find model from turn.started or config runes
    model =
      runes
      |> Enum.find_value(fn r ->
        cond do
          r.kind == "turn.started" -> get_in(r.payload, ["model"])
          r.kind == "session.config" -> get_in(r.payload, ["model"])
          true -> nil
        end
      end)

    turn_count =
      Enum.count(runes, fn r -> r.kind == "turn.started" end)

    %{
      "model" => model,
      "total_input_tokens" => total_input,
      "total_output_tokens" => total_output,
      "turn_count" => turn_count
    }
  end

  # -------------------------------------------------------------------
  # System info
  # -------------------------------------------------------------------

  defp collect_system_info do
    %{
      "echs_version" => echs_version(),
      "elixir_version" => System.version(),
      "otp_version" => :erlang.system_info(:otp_release) |> List.to_string(),
      "node" => Atom.to_string(node()),
      "os" => os_info(),
      "bundle_schema_version" => @bundle_version
    }
  end

  defp echs_version do
    case Application.spec(:echs_core, :vsn) do
      nil -> "dev"
      vsn -> List.to_string(vsn)
    end
  end

  defp os_info do
    {family, name} = :os.type()
    "#{family}:#{name}"
  end

  # -------------------------------------------------------------------
  # Stats computation
  # -------------------------------------------------------------------

  defp compute_stats(original_runes, sanitized_runes) do
    timestamps =
      original_runes
      |> Enum.map(& &1.ts_ms)
      |> Enum.reject(&is_nil/1)

    first_ts = if timestamps != [], do: Enum.min(timestamps), else: nil
    last_ts = if timestamps != [], do: Enum.max(timestamps), else: nil

    tool_call_count =
      Enum.count(original_runes, fn r -> r.kind == "tool.call" end)

    error_count =
      Enum.count(original_runes, fn r ->
        r.kind in ["turn.error", "tool.error", "provider.error"]
      end)

    truncated_count =
      Enum.count(sanitized_runes, fn rune ->
        get_in(rune, ["payload", "_truncated"]) == true
      end)

    %{
      "original_rune_count" => length(original_runes),
      "included_rune_count" => length(sanitized_runes),
      "tool_call_count" => tool_call_count,
      "error_count" => error_count,
      "truncated_count" => truncated_count,
      "first_ts_ms" => first_ts,
      "last_ts_ms" => last_ts
    }
  end

  # -------------------------------------------------------------------
  # Secret redaction (string-level)
  # -------------------------------------------------------------------

  defp redact_string(value) do
    Enum.reduce(@secret_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  # -------------------------------------------------------------------
  # Size enforcement
  # -------------------------------------------------------------------

  defp enforce_size_limit(bundle, max_bytes) do
    json = Jason.encode!(bundle)

    if byte_size(json) <= max_bytes do
      bundle
    else
      # Progressively drop runes from the middle to stay under limit
      trim_runes_to_fit(bundle, max_bytes)
    end
  end

  defp trim_runes_to_fit(bundle, max_bytes) do
    runes = Map.get(bundle, :runes, [])
    total = length(runes)

    if total <= 2 do
      # Can't trim further — drop snapshot if present
      bundle = Map.put(bundle, :snapshot, nil)
      maybe_truncate_final(bundle, max_bytes)
    else
      # Keep first 25% and last 25%, drop middle
      keep_count = max(div(total, 2), 2)
      head_count = div(keep_count, 2)
      tail_count = keep_count - head_count

      head = Enum.take(runes, head_count)
      tail = Enum.take(runes, -tail_count)
      dropped = total - head_count - tail_count

      marker = %{
        "kind" => "_debug_bundle.trimmed",
        "payload" => %{"dropped_rune_count" => dropped},
        "event_id" => nil,
        "rune_id" => "trim_marker",
        "conversation_id" => bundle[:conversation_id],
        "turn_id" => nil,
        "agent_id" => nil,
        "visibility" => "internal",
        "ts_ms" => System.system_time(:millisecond),
        "tags" => [],
        "schema_version" => 1
      }

      trimmed_runes = head ++ [marker] ++ tail
      bundle = Map.put(bundle, :runes, trimmed_runes)

      # Update stats
      bundle =
        update_in(bundle, [:stats], fn stats ->
          Map.merge(stats || %{}, %{
            "included_rune_count" => length(trimmed_runes),
            "trimmed" => true,
            "dropped_rune_count" => dropped
          })
        end)

      json = Jason.encode!(bundle)

      if byte_size(json) <= max_bytes do
        bundle
      else
        # Still too large — recurse with the trimmed list
        trim_runes_to_fit(bundle, max_bytes)
      end
    end
  end

  defp maybe_truncate_final(bundle, max_bytes) do
    json = Jason.encode!(bundle)

    if byte_size(json) <= max_bytes do
      bundle
    else
      # Last resort: drop all runes and snapshot
      bundle
      |> Map.put(:runes, [])
      |> Map.put(:snapshot, nil)
      |> update_in([:stats], fn stats ->
        Map.merge(stats || %{}, %{
          "included_rune_count" => 0,
          "trimmed" => true,
          "note" => "Bundle exceeded max_bytes; all runes dropped"
        })
      end)
    end
  end

  # -------------------------------------------------------------------
  # Formatting helpers
  # -------------------------------------------------------------------

  defp format_timestamp(nil), do: "unknown"

  defp format_timestamp(ms) when is_integer(ms) do
    DateTime.from_unix!(ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp format_kind_counts(kinds) when map_size(kinds) == 0, do: "(none)"

  defp format_kind_counts(kinds) do
    kinds
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end

  defp format_time_span(nil, _), do: "unknown"
  defp format_time_span(_, nil), do: "unknown"

  defp format_time_span(first_ms, last_ms) do
    diff = last_ms - first_ms

    cond do
      diff < 1_000 -> "#{diff}ms"
      diff < 60_000 -> "#{Float.round(diff / 1_000, 1)}s"
      diff < 3_600_000 -> "#{Float.round(diff / 60_000, 1)}m"
      true -> "#{Float.round(diff / 3_600_000, 1)}h"
    end
  end
end
