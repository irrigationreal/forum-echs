defmodule EchsClaude do
  @moduledoc """
  Minimal Claude/Anthropic messages API client used by ECHS.

  Uses Claude Code OAuth token + base URL from ~/.claude/settings.json (or env),
  normalizes tool payloads, and translates streaming events into the
  OpenAI-style event shapes expected by EchsCore.
  """

  require Logger

  alias EchsCodex.SSE

  @default_base_url "https://api.anthropic.com"
  @default_max_tokens 4096
  @models_cache_ttl_ms 300_000
  @tool_prefix ""
  @instructions_marker "<CLAUDE_INSTRUCTIONS>"

  @required_betas ["oauth-2025-04-20"]

  def stream_response(opts) do
    model_alias = Keyword.get(opts, :model, "opus")
    instructions = Keyword.get(opts, :instructions, "")
    input = Keyword.get(opts, :input, [])
    tools = Keyword.get(opts, :tools, [])
    on_event = Keyword.fetch!(opts, :on_event)
    max_tokens = Keyword.get(opts, :max_tokens, default_max_tokens())

    config = load_config()
    model = resolve_model_alias(model_alias, config)

    {input, _injected?} = ensure_instructions_in_first_user_message(input, instructions)
    messages = build_messages(input)
    tools_payload = build_tools(tools)

    body =
      %{
        "model" => model,
        "messages" => messages,
        "max_tokens" => max_tokens,
        "stream" => true
      }
      |> maybe_put("tools", tools_payload)

    headers = build_headers(config)

    Logger.debug(fn ->
      "Claude request to #{config.base_url}/v1/messages model=#{model} messages=#{length(messages)} tools=#{length(tools_payload)}"
    end)

    {:ok, state_agent} = Agent.start_link(fn -> %{text: "", blocks: %{}, had_text: false} end)

    handler = build_sse_handler(state_agent, on_event)

    request =
      Req.new(
        url: "#{config.base_url}/v1/messages",
        method: :post,
        headers: headers,
        json: body,
        receive_timeout: :infinity,
        into: handler
      )

    result =
      case Req.request(request) do
        {:ok, %{status: 200}} = ok ->
          ok

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, _} = error ->
          error
      end

    Agent.stop(state_agent)
    result
  end

  def list_models do
    config = load_config()
    fetch_models(config)
  end

  defp build_sse_handler(state_agent, on_event) do
    fn {:data, data}, {req, resp} ->
      sse_state = Map.get(resp.private, :echs_sse_state, SSE.new_state())
      {sse_state, events} = SSE.parse(sse_state, data)

      Enum.each(events, fn event ->
        handle_anthropic_event(state_agent, event, on_event)
      end)

      resp = %{resp | private: Map.put(resp.private, :echs_sse_state, sse_state)}
      {:cont, {req, resp}}
    end
  end

  defp handle_anthropic_event(state_agent, event, on_event) do
    case event["type"] do
      "message_start" ->
        on_event.(event)

      "message_delta" ->
        on_event.(event)

      "content_block_start" ->
        start_content_block(state_agent, event, on_event)

      "content_block_delta" ->
        handle_content_delta(state_agent, event, on_event)

      "content_block_stop" ->
        finish_content_block(state_agent, event, on_event)

      "message_stop" ->
        finish_message(state_agent, on_event)

      _ ->
        :ok
    end
  end

  defp start_content_block(state_agent, %{"index" => index, "content_block" => block}, on_event)
       when is_map(block) do
    Agent.update(state_agent, fn state ->
      blocks = Map.put(state.blocks, index, normalize_block(block))
      %{state | blocks: blocks}
    end)

    case block do
      %{"type" => "tool_use"} ->
        item = tool_block_to_item(block, %{})
        on_event.(%{"type" => "response.output_item.added", "item" => item})

      _ ->
        :ok
    end
  end

  defp start_content_block(_state_agent, _event, _on_event), do: :ok

  defp handle_content_delta(state_agent, %{"index" => index, "delta" => delta}, on_event)
       when is_map(delta) do
    case delta["type"] do
      "text_delta" ->
        text = delta["text"] || ""

        if text != "" do
          Agent.update(state_agent, fn state ->
            %{state | text: state.text <> text, had_text: true}
          end)

          on_event.(%{"type" => "response.output_text.delta", "delta" => text})
        end

      "input_json_delta" ->
        json = delta["partial_json"] || delta["text"] || ""

        Agent.update(state_agent, fn state ->
          blocks =
            Map.update(
              state.blocks,
              index,
              %{"type" => "tool_use", "input_json" => json},
              fn block ->
                Map.update(block, "input_json", json, fn existing -> existing <> json end)
              end
            )

          %{state | blocks: blocks}
        end)

      _ ->
        :ok
    end
  end

  defp handle_content_delta(_state_agent, _event, _on_event), do: :ok

  defp finish_content_block(state_agent, %{"index" => index}, on_event) do
    block =
      Agent.get_and_update(state_agent, fn state ->
        {Map.get(state.blocks, index), %{state | blocks: Map.delete(state.blocks, index)}}
      end)

    case block do
      %{"type" => "tool_use"} ->
        item = tool_block_to_item(block, block_input(block))
        on_event.(%{"type" => "response.output_item.done", "item" => item})

      _ ->
        :ok
    end
  end

  defp finish_content_block(_state_agent, _event, _on_event), do: :ok

  defp finish_message(state_agent, on_event) do
    %{text: text, had_text: had_text} = Agent.get(state_agent, & &1)

    if had_text and String.trim(text) != "" do
      item = %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }

      on_event.(%{"type" => "response.output_item.done", "item" => item})
    end

    Agent.update(state_agent, fn state -> %{state | text: "", had_text: false} end)
  end

  defp normalize_block(%{"type" => "tool_use"} = block) do
    block
    |> Map.put_new("input_json", "")
  end

  defp normalize_block(block), do: block

  defp tool_block_to_item(block, input) do
    name = block["name"] || ""
    call_id = block["id"] || block["tool_use_id"] || "toolu_" <> random_id()
    stripped_name = strip_tool_prefix(name)

    arguments =
      case input do
        %{} -> Jason.encode!(input)
        other -> Jason.encode!(%{"input" => other})
      end

    %{
      "type" => "function_call",
      "name" => stripped_name,
      "arguments" => arguments,
      "call_id" => call_id
    }
  end

  defp block_input(block) do
    cond do
      is_binary(block["input_json"]) and block["input_json"] != "" ->
        decode_json(block["input_json"])

      is_map(block["input"]) ->
        block["input"]

      true ->
        %{}
    end
  end

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} -> decoded
      {:ok, other} -> %{"value" => other}
      _ -> %{}
    end
  end

  defp build_messages(input) when is_list(input) do
    input
    |> Enum.flat_map(&item_to_messages/1)
    |> merge_consecutive_roles()
  end

  defp build_messages(_), do: []

  defp item_to_messages(%{"type" => "message", "role" => role, "content" => content})
       when is_list(content) do
    [%{"role" => role, "content" => normalize_content(content)}]
  end

  defp item_to_messages(%{"type" => "message", "role" => role, "content" => content})
       when is_binary(content) do
    [%{"role" => role, "content" => [%{"type" => "text", "text" => content}]}]
  end

  defp item_to_messages(%{"type" => "function_call"} = item) do
    name = item["name"] || ""
    call_id = item["call_id"] || item["id"] || "toolu_" <> random_id()
    args = decode_json(item["arguments"] || "{}")

    [
      %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => call_id,
            "name" => prefix_tool_name(name),
            "input" => args
          }
        ]
      }
    ]
  end

  defp item_to_messages(%{"type" => "local_shell_call"} = item) do
    command =
      case get_in(item, ["action", "command"]) do
        ["bash", "-lc", cmd] -> cmd
        [cmd | _] -> cmd
        _ -> ""
      end

    call_id = item["call_id"] || item["id"] || "toolu_" <> random_id()

    [
      %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => call_id,
            "name" => prefix_tool_name("shell"),
            "input" => %{"command" => command}
          }
        ]
      }
    ]
  end

  defp item_to_messages(%{"type" => "function_call_output"} = item) do
    call_id = item["call_id"] || item["id"] || "toolu_" <> random_id()
    output = item["output"] || ""

    [
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => call_id,
            "content" => output,
            "is_error" => false
          }
        ]
      }
    ]
  end

  defp item_to_messages(_), do: []

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "input_text", "text" => text} ->
        [%{"type" => "text", "text" => to_string(text)}]

      %{"type" => "output_text", "text" => text} ->
        [%{"type" => "text", "text" => to_string(text)}]

      %{"type" => "text", "text" => text} ->
        [%{"type" => "text", "text" => to_string(text)}]

      %{"type" => "input_image", "image_url" => url} when is_binary(url) and url != "" ->
        [%{"type" => "text", "text" => "[image: #{url}]"}]

      _ ->
        []
    end)
  end

  defp normalize_content(content) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp normalize_content(_), do: []

  defp merge_consecutive_roles(messages) do
    Enum.reduce(messages, [], fn message, acc ->
      case acc do
        [] ->
          [message]

        [%{"role" => role, "content" => content} = last | rest] ->
          if role == message["role"] do
            merged = %{last | "content" => content ++ List.wrap(message["content"])}
            rest ++ [merged]
          else
            acc ++ [message]
          end
      end
    end)
  end

  defp build_tools(tools) when is_list(tools) do
    tools
    |> Enum.filter(fn tool ->
      (tool["type"] == "function" or tool["type"] == nil) and
        is_binary(tool["name"]) and String.trim(tool["name"]) != ""
    end)
    |> Enum.map(fn tool ->
      %{
        "name" => prefix_tool_name(tool["name"]),
        "description" => tool["description"] || "",
        "input_schema" => tool["parameters"] || %{"type" => "object"}
      }
    end)
  end

  defp build_tools(_), do: []

  defp ensure_instructions_in_first_user_message(items, instructions) do
    instructions = to_string(instructions || "")

    cond do
      instructions == "" ->
        {items, false}

      instructions_present?(items) ->
        {items, false}

      true ->
        {inject_instructions(items, instructions), true}
    end
  end

  defp instructions_present?(items) when is_list(items) do
    Enum.any?(items, fn
      %{"type" => "message", "role" => "user", "content" => content} ->
        content_contains_marker?(content)

      _ ->
        false
    end)
  end

  defp instructions_present?(_), do: false

  defp content_contains_marker?(content) when is_binary(content) do
    String.contains?(content, @instructions_marker)
  end

  defp content_contains_marker?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"text" => text} when is_binary(text) -> String.contains?(text, @instructions_marker)
      _ -> false
    end)
  end

  defp content_contains_marker?(_), do: false

  defp inject_instructions(items, instructions) when is_list(items) do
    Enum.map_reduce(items, false, fn item, injected? ->
      if injected? do
        {item, injected?}
      else
        case item do
          %{"type" => "message", "role" => "user"} = message ->
            {inject_into_message(message, instructions), true}

          _ ->
            {item, injected?}
        end
      end
    end)
    |> then(fn {items, _} -> items end)
  end

  defp inject_instructions(items, _instructions), do: items

  defp inject_into_message(%{"content" => content} = message, instructions)
       when is_binary(content) do
    prefix = "#{@instructions_marker}\n#{instructions}\n</CLAUDE_INSTRUCTIONS>\n\n"
    %{message | "content" => prefix <> content}
  end

  defp inject_into_message(%{"content" => content} = message, instructions)
       when is_list(content) do
    prefix = "#{@instructions_marker}\n#{instructions}\n</CLAUDE_INSTRUCTIONS>\n\n"
    injected = [%{"type" => "input_text", "text" => prefix} | content]
    %{message | "content" => injected}
  end

  defp inject_into_message(message, instructions) do
    prefix = "#{@instructions_marker}\n#{instructions}\n</CLAUDE_INSTRUCTIONS>\n\n"
    Map.put(message, "content", prefix)
  end

  defp build_headers(%{token: token} = config) do
    [
      {"authorization", "Bearer #{token}"},
      {"anthropic-beta", merge_betas(config.beta)},
      {"user-agent", config.user_agent},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  defp merge_betas(nil), do: Enum.join(@required_betas, ",")

  defp merge_betas(existing) do
    existing_list =
      existing
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    @required_betas
    |> Enum.concat(existing_list)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  defp maybe_put(map, _key, value) when value in [nil, [], ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp prefix_tool_name(name) when is_binary(name), do: @tool_prefix <> name
  defp prefix_tool_name(_), do: @tool_prefix <> "tool"

  defp strip_tool_prefix(name) when is_binary(name) do
    if @tool_prefix == "" do
      name
    else
      if String.starts_with?(name, @tool_prefix) do
        String.replace_prefix(name, @tool_prefix, "")
      else
        name
      end
    end
  end

  defp strip_tool_prefix(_), do: ""

  defp resolve_model_alias(model, config) when is_binary(model) do
    alias_name = String.downcase(String.trim(model))

    case alias_name do
      "opus" -> latest_model_id(config, "opus") || model
      "sonnet" -> latest_model_id(config, "sonnet") || model
      "haiku" -> latest_model_id(config, "haiku") || model
      _ -> model
    end
  end

  defp resolve_model_alias(model, _config), do: model

  defp latest_model_id(config, family) do
    fetch_models(config)
    |> Enum.filter(fn model -> String.contains?(String.downcase(model["id"] || ""), family) end)
    |> Enum.sort_by(fn model -> parse_datetime(model["created_at"]) end, :desc)
    |> List.first()
    |> case do
      nil -> nil
      %{"id" => id} -> id
    end
  end

  defp fetch_models(config) do
    cache_key = {__MODULE__, :models_cache}
    now = System.system_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      %{fetched_at: fetched_at, models: models} when now - fetched_at < @models_cache_ttl_ms ->
        models

      _ ->
        url = "#{config.base_url}/v1/models"

        headers = [
          {"authorization", "Bearer #{config.token}"},
          {"anthropic-beta", merge_betas(config.beta)},
          {"user-agent", config.user_agent},
          {"accept", "application/json"}
        ]

        case Req.get(url, headers: headers) do
          {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
            :persistent_term.put(cache_key, %{fetched_at: now, models: models})
            models

          {:ok, %{status: status, body: body}} ->
            Logger.warning("Claude models fetch failed: status=#{status} body=#{inspect(body)}")
            []

          {:error, reason} ->
            Logger.warning("Claude models fetch error: #{inspect(reason)}")
            []
        end
    end
  end

  defp parse_datetime(nil), do: 0
  defp parse_datetime(value) when is_integer(value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp parse_datetime(_), do: 0

  defp load_config do
    settings = load_settings()

    %{
      base_url:
        env_or_setting(["ANTHROPIC_BASE_URL"], settings, @default_base_url)
        |> String.trim()
        |> String.trim_trailing("/"),
      token:
        env_or_setting(["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"], settings, nil)
        |> normalize_token(),
      beta: env_or_setting(["ANTHROPIC_BETA"], settings, nil),
      user_agent: env_or_setting(["CLAUDE_CODE_USER_AGENT"], settings, "claude-cli/2.1.12")
    }
    |> ensure_token!()
  end

  defp ensure_token!(%{token: token} = config) when is_binary(token) and token != "" do
    config
  end

  defp ensure_token!(_config) do
    raise "Claude auth token missing. Set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_AUTH_TOKEN."
  end

  defp env_or_setting(keys, settings, default) do
    Enum.find_value(keys, default, fn key ->
      System.get_env(key) || get_in(settings, ["env", key])
    end)
  end

  defp normalize_token(nil), do: ""
  defp normalize_token(token), do: token |> to_string() |> String.trim()

  defp load_settings do
    path = settings_path()

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = json} -> json
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp settings_path do
    Path.join([System.get_env("HOME") || "", ".claude", "settings.json"])
  end

  defp random_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end

  defp default_max_tokens do
    case System.get_env("ECHS_CLAUDE_MAX_TOKENS") do
      nil ->
        @default_max_tokens

      value ->
        value
        |> to_string()
        |> Integer.parse()
        |> case do
          {int, _} when int > 0 -> int
          _ -> @default_max_tokens
        end
    end
  end
end
