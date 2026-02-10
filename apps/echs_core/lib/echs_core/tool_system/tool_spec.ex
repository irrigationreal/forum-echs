defmodule EchsCore.ToolSystem.ToolSpec do
  @moduledoc """
  Canonical tool specification with metadata.

  Extends the basic tool definition (name, description, parameters) with
  metadata for the approval engine, scheduling, and observability:

    * `side_effects` — does this tool modify external state?
    * `idempotent` — safe to retry if result is lost?
    * `streaming` — does this tool produce streaming progress?
    * `requires_approval` — override approval policy for this tool?
    * `timeout` — max execution time in milliseconds
    * `max_output_bytes` — truncation limit for tool output
    * `provenance` — where this tool came from (built_in, remote, mcp, custom)
    * `enabled` — runtime enable/disable toggle
  """

  @type provenance :: :built_in | :remote | :mcp | :custom
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          type: String.t(),
          side_effects: boolean(),
          idempotent: boolean(),
          streaming: boolean(),
          requires_approval: :inherit | :always | :never,
          timeout: non_neg_integer(),
          max_output_bytes: non_neg_integer(),
          provenance: provenance(),
          enabled: boolean(),
          metadata: map()
        }

  @default_timeout 120_000
  @default_max_output_bytes 100_000

  defstruct [
    :name,
    :description,
    parameters: %{"type" => "object", "properties" => %{}},
    type: "function",
    side_effects: true,
    idempotent: false,
    streaming: false,
    requires_approval: :inherit,
    timeout: @default_timeout,
    max_output_bytes: @default_max_output_bytes,
    provenance: :built_in,
    enabled: true,
    metadata: %{}
  ]

  @doc """
  Create a ToolSpec from a legacy tool definition map.
  Preserves all existing fields and adds defaults for new metadata.
  """
  @spec from_legacy(map()) :: t()
  def from_legacy(tool_map) when is_map(tool_map) do
    %__MODULE__{
      name: tool_map["name"] || "",
      description: tool_map["description"] || "",
      parameters: tool_map["parameters"] || %{"type" => "object"},
      type: tool_map["type"] || "function",
      side_effects: Map.get(tool_map, "side_effects", infer_side_effects(tool_map["name"])),
      idempotent: Map.get(tool_map, "idempotent", infer_idempotent(tool_map["name"])),
      streaming: Map.get(tool_map, "streaming", false),
      requires_approval: parse_approval(Map.get(tool_map, "requires_approval")),
      timeout: Map.get(tool_map, "timeout", @default_timeout),
      max_output_bytes: Map.get(tool_map, "max_output_bytes", @default_max_output_bytes),
      provenance: parse_provenance(Map.get(tool_map, "provenance")),
      enabled: Map.get(tool_map, "enabled", true),
      metadata: Map.get(tool_map, "metadata", %{})
    }
  end

  @doc """
  Convert a ToolSpec to a legacy tool definition map (for provider API calls).
  Strips metadata fields and returns the basic tool definition.
  """
  @spec to_provider_format(t()) :: map()
  def to_provider_format(%__MODULE__{} = spec) do
    %{
      "type" => spec.type,
      "name" => spec.name,
      "description" => spec.description,
      "parameters" => spec.parameters
    }
  end

  @doc """
  Convert a ToolSpec to a JSON-serializable map (includes all metadata).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec) do
    %{
      "name" => spec.name,
      "description" => spec.description,
      "parameters" => spec.parameters,
      "type" => spec.type,
      "side_effects" => spec.side_effects,
      "idempotent" => spec.idempotent,
      "streaming" => spec.streaming,
      "requires_approval" => Atom.to_string(spec.requires_approval),
      "timeout" => spec.timeout,
      "max_output_bytes" => spec.max_output_bytes,
      "provenance" => Atom.to_string(spec.provenance),
      "enabled" => spec.enabled,
      "metadata" => spec.metadata
    }
  end

  # -------------------------------------------------------------------
  # Tool attribute inference from name
  # -------------------------------------------------------------------

  @read_only_tools MapSet.new([
    "read_file", "list_dir", "grep_files", "view_image",
    "blackboard_read", "recall_thread_history"
  ])

  @idempotent_tools MapSet.new([
    "read_file", "list_dir", "grep_files", "view_image",
    "blackboard_read", "blackboard_write"
  ])

  defp infer_side_effects(nil), do: true
  defp infer_side_effects(name), do: not MapSet.member?(@read_only_tools, name)

  defp infer_idempotent(nil), do: false
  defp infer_idempotent(name), do: MapSet.member?(@idempotent_tools, name)

  defp parse_approval("always"), do: :always
  defp parse_approval("never"), do: :never
  defp parse_approval(:always), do: :always
  defp parse_approval(:never), do: :never
  defp parse_approval(_), do: :inherit

  defp parse_provenance("remote"), do: :remote
  defp parse_provenance("mcp"), do: :mcp
  defp parse_provenance("custom"), do: :custom
  defp parse_provenance(:remote), do: :remote
  defp parse_provenance(:mcp), do: :mcp
  defp parse_provenance(:custom), do: :custom
  defp parse_provenance(_), do: :built_in
end
