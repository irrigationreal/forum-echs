defmodule EchsCore.Memory.Retrieval do
  @moduledoc """
  Memory retrieval and deterministic context injection.

  Provides lexical retrieval baseline (deterministic), plan-aware filtering,
  and structured Memory Context block generation for injection into prompts.

  ## Retrieval Budget

  Each retrieval call respects configurable limits:
  - max_memories: maximum number of memories to return
  - max_tokens: approximate token budget for memory content
  - min_confidence: minimum confidence threshold
  """

  alias EchsCore.Memory.{Memory, Store}

  @default_max_memories 10
  @default_max_tokens 2000
  @default_min_confidence 0.3
  @approx_chars_per_token 4

  @type retrieval_opts :: %{
          optional(:max_memories) => non_neg_integer(),
          optional(:max_tokens) => non_neg_integer(),
          optional(:min_confidence) => float(),
          optional(:privacy) => Memory.privacy(),
          optional(:memory_types) => [Memory.memory_type()],
          optional(:tags) => [String.t()],
          optional(:conversation_id) => String.t(),
          optional(:plan_task_ids) => [String.t()]
        }

  @type retrieval_result :: %{
          memories: [Memory.t()],
          total_found: non_neg_integer(),
          tokens_used: non_neg_integer(),
          truncated: boolean()
        }

  @doc """
  Retrieve relevant memories based on a query string and options.

  Uses lexical matching (deterministic) as the baseline strategy.
  Results are ranked by relevance score (combination of text match + confidence).
  """
  @spec retrieve(GenServer.server(), String.t(), retrieval_opts()) :: retrieval_result()
  def retrieve(store, query, opts \\ %{}) do
    max_memories = Map.get(opts, :max_memories, @default_max_memories)
    max_tokens = Map.get(opts, :max_tokens, @default_max_tokens)
    min_confidence = Map.get(opts, :min_confidence, @default_min_confidence)
    privacy = Map.get(opts, :privacy, :internal)
    memory_types = Map.get(opts, :memory_types)
    required_tags = Map.get(opts, :tags)
    conversation_id = Map.get(opts, :conversation_id)

    # Get candidate memories
    candidates = get_candidates(store, conversation_id, required_tags, privacy, min_confidence)

    # Filter by type if specified
    candidates =
      if memory_types do
        Enum.filter(candidates, &(&1.memory_type in memory_types))
      else
        candidates
      end

    # Score and rank
    query_terms = tokenize(query)

    scored =
      candidates
      |> Enum.map(fn mem ->
        score = compute_relevance(mem, query_terms)
        {mem, score}
      end)
      |> Enum.filter(fn {_mem, score} -> score > 0 end)
      |> Enum.sort_by(fn {_mem, score} -> score end, :desc)

    # Apply budget limits
    {selected, tokens_used, truncated} =
      apply_budget(scored, max_memories, max_tokens)

    %{
      memories: selected,
      total_found: length(scored),
      tokens_used: tokens_used,
      truncated: truncated
    }
  end

  @doc """
  Generate a structured Memory Context block for injection into a prompt.

  Returns a string formatted as a structured block that can be prepended
  to system instructions or injected into the conversation context.
  """
  @spec build_context_block(retrieval_result()) :: String.t()
  def build_context_block(%{memories: []}) do
    ""
  end

  def build_context_block(%{memories: memories, tokens_used: tokens_used, truncated: truncated}) do
    header =
      "<memory-context memories=\"#{length(memories)}\" tokens=\"#{tokens_used}\"#{if truncated, do: " truncated=\"true\"", else: ""}>"

    body =
      memories
      |> Enum.with_index(1)
      |> Enum.map(fn {mem, i} ->
        tags_str = if mem.tags != [], do: " tags=\"#{Enum.join(mem.tags, ",")}\"", else: ""
        type_str = Atom.to_string(mem.memory_type)
        conf_str = Float.round(mem.confidence, 2) |> to_string()

        "<memory index=\"#{i}\" type=\"#{type_str}\" confidence=\"#{conf_str}\"#{tags_str}>\n#{mem.content}\n</memory>"
      end)
      |> Enum.join("\n")

    "#{header}\n#{body}\n</memory-context>"
  end

  @doc """
  Retrieve memories relevant to a specific plan task.

  Filters by task-related tags and the task's description content.
  """
  @spec retrieve_for_task(GenServer.server(), map(), retrieval_opts()) :: retrieval_result()
  def retrieve_for_task(store, task, opts \\ %{}) do
    # Build query from task title + description
    query = "#{Map.get(task, :title, "")} #{Map.get(task, :description, "")}"

    # Merge task tags if available
    task_tags = Map.get(task, :tags, [])
    opts = if task_tags != [], do: Map.put(opts, :tags, task_tags), else: opts

    retrieve(store, query, opts)
  end

  # --- Internal ---

  defp get_candidates(store, conversation_id, required_tags, privacy, min_confidence) do
    filter_opts = [privacy: privacy, min_confidence: min_confidence, exclude_expired: true]

    cond do
      required_tags && required_tags != [] ->
        Store.query_by_tags(store, required_tags, filter_opts)

      conversation_id ->
        # Get both conversation-specific and global memories
        conv_memories = Store.query_by_conversation(store, conversation_id, filter_opts)

        global_memories =
          Store.list(store, filter_opts)
          |> Enum.filter(&is_nil(&1.conversation_id))

        (conv_memories ++ global_memories) |> Enum.uniq_by(& &1.memory_id)

      true ->
        Store.list(store, filter_opts)
    end
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp compute_relevance(memory, query_terms) do
    content_lower = String.downcase(memory.content)

    # Term overlap score
    matching_terms =
      Enum.count(query_terms, fn term ->
        String.contains?(content_lower, term)
      end)

    term_score =
      if length(query_terms) > 0 do
        matching_terms / length(query_terms)
      else
        0.0
      end

    # Tag bonus
    tag_bonus =
      if memory.tags != [] do
        tag_matches =
          Enum.count(query_terms, fn term ->
            Enum.any?(memory.tags, &String.contains?(String.downcase(&1), term))
          end)

        tag_matches * 0.2
      else
        0.0
      end

    # Type bonus (procedural and decision memories get slight boost for task queries)
    type_bonus =
      case memory.memory_type do
        :procedural -> 0.1
        :decision -> 0.05
        _ -> 0.0
      end

    # Combine: relevance * confidence
    raw_score = term_score + tag_bonus + type_bonus
    raw_score * memory.confidence
  end

  defp apply_budget(scored_memories, max_memories, max_tokens) do
    max_chars = max_tokens * @approx_chars_per_token

    {selected, tokens_used, _chars_used, truncated} =
      scored_memories
      |> Enum.reduce_while({[], 0, 0, false}, fn {mem, _score}, {acc, tokens, chars, _trunc} ->
        mem_chars = String.length(mem.content)
        mem_tokens = div(mem_chars, @approx_chars_per_token) + 1

        cond do
          length(acc) >= max_memories ->
            {:halt, {acc, tokens, chars, true}}

          chars + mem_chars > max_chars ->
            {:halt, {acc, tokens, chars, true}}

          true ->
            {:cont, {acc ++ [mem], tokens + mem_tokens, chars + mem_chars, false}}
        end
      end)

    {selected, tokens_used, truncated}
  end
end
