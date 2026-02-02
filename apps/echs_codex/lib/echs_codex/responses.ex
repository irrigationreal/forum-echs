defmodule EchsCodex.Responses do
  @moduledoc """
  Handles calls to the Codex responses API endpoint.
  Supports streaming SSE responses.
  """

  require Logger

  @default_base_url "https://codex.ppflix.net/v1/responses"
  @default_compact_url "https://codex.ppflix.net/v1/responses/compact"

  @default_model "gpt-5.2-codex"
  @max_error_body_bytes 50_000

  @doc """
  Stream a response from the Codex API.

  Options:
    - :model - model to use (default: gpt-5.2-codex)
    - :instructions - system prompt
    - :input - list of input items (history)
    - :tools - list of tool definitions
    - :reasoning - reasoning effort (none|minimal|low|medium|high|xhigh)
    - :on_event - callback function for SSE events
    - :parallel_tool_calls - allow parallel tool calls (default: true)
    - :req_opts - extra Req options (ex: retry/max_retries/plug for tests)
  """
  def stream_response(opts) do
    model = Keyword.get(opts, :model, @default_model)
    instructions = Keyword.fetch!(opts, :instructions)
    input = Keyword.get(opts, :input, []) |> normalize_input_items()
    tools = Keyword.get(opts, :tools, [])
    reasoning = Keyword.get(opts, :reasoning, "medium")
    on_event = Keyword.fetch!(opts, :on_event)
    parallel_tool_calls = Keyword.get(opts, :parallel_tool_calls, true)
    req_opts = Keyword.get(opts, :req_opts, []) |> Keyword.put_new(:retry, :transient)

    reasoning_payload = build_reasoning_payload(reasoning)
    summary_requested = reasoning_summary_requested?(reasoning_payload)

    body =
      %{
        "model" => model,
        "instructions" => instructions,
        "input" => input,
        "tools" => tools,
        "tool_choice" => "auto",
        "parallel_tool_calls" => parallel_tool_calls,
        "store" => false,
        "stream" => true
      }
      |> maybe_put("reasoning", reasoning_payload)

    headers = auth_headers()

    Logger.debug(fn ->
      "Codex request to #{base_url()} model=#{model} items=#{length(input)} tools=#{length(tools)}"
    end)

    meta = %{model: model, items: length(input), tools: length(tools)}

    do_stream_request(body, headers, on_event, req_opts, summary_requested,
      auth_refreshed?: false,
      summary_dropped?: false,
      meta: meta
    )
  end

  @doc """
  Compact conversation history via the compaction endpoint.

  Options:
    - :model - model to use (default: gpt-5.2-codex)
    - :instructions - system prompt
    - :input - list of input items (history)
    - :req_opts - extra Req options (ex: retry/max_retries/plug for tests)
  """
  def compact(opts) do
    model = Keyword.get(opts, :model, @default_model)
    instructions = Keyword.fetch!(opts, :instructions)
    input = Keyword.fetch!(opts, :input) |> normalize_input_items()
    req_opts = Keyword.get(opts, :req_opts, []) |> Keyword.put_new(:retry, :transient)

    body = %{
      "model" => model,
      "instructions" => instructions,
      "input" => input
    }

    headers = auth_headers()
    # Remove accept: text/event-stream for non-streaming endpoint
    headers = Enum.reject(headers, fn {k, _} -> k == "accept" end)
    headers = [{"accept", "application/json"} | headers]

    meta = %{model: model, items: length(input), tools: 0}

    do_compact_request(body, headers, req_opts, auth_refreshed?: false, meta: meta)
  end

  defp build_reasoning_payload(reasoning) do
    summary_override =
      System.get_env("ECHS_REASONING_SUMMARY")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized_summary =
      case summary_override do
        "" -> nil
        "auto" -> "auto"
        "none" -> nil
        "detailed" -> "detailed"
        "concise" -> "concise"
        "short" -> "concise"
        _ -> nil
      end

    effort =
      cond do
        is_binary(reasoning) and String.trim(reasoning) == "" -> "medium"
        reasoning == nil -> "medium"
        is_binary(reasoning) -> String.trim(reasoning)
        true -> "medium"
      end

    effort = if effort == "none", do: "medium", else: effort

    summary = normalized_summary || "auto"
    %{"effort" => effort, "summary" => summary}
  end

  defp maybe_put(map, _key, payload) when map_size(payload) == 0, do: map
  defp maybe_put(map, key, payload), do: Map.put(map, key, payload)

  defp normalize_input_items(items) when is_list(items) do
    Enum.map(items, &normalize_input_item/1)
  end

  defp normalize_input_items(other), do: other

  defp normalize_input_item(%{"type" => "message", "role" => role, "content" => content} = item) do
    %{item | "content" => normalize_message_content(role, content)}
  end

  defp normalize_input_item(%{type: "message", role: role, content: content} = item) do
    item
    |> Map.put("type", "message")
    |> Map.put("role", role)
    |> Map.put("content", normalize_message_content(role, content))
  end

  defp normalize_input_item(item), do: item

  defp normalize_message_content(role, content) when is_binary(content) do
    [%{"type" => normalize_text_type(role), "text" => content}]
  end

  defp normalize_message_content(role, content) when is_list(content) do
    Enum.map(content, &normalize_content_item(role, &1))
  end

  defp normalize_message_content(_role, content), do: content

  defp normalize_content_item(role, item) when is_map(item) do
    type = Map.get(item, "type") || Map.get(item, :type)

    if type in ["text", :text] do
      item
      |> Map.put("type", normalize_text_type(role))
      |> Map.delete(:type)
    else
      item
    end
  end

  defp normalize_content_item(_role, item), do: item

  defp normalize_text_type(role) when is_binary(role) do
    case String.downcase(role) do
      "assistant" -> "output_text"
      _ -> "input_text"
    end
  end

  defp normalize_text_type(role) when is_atom(role) do
    if role == :assistant, do: "output_text", else: "input_text"
  end

  defp normalize_text_type(_), do: "input_text"

  defp reasoning_summary_requested?(%{"summary" => summary})
       when summary not in [nil, "", "none"],
       do: true

  defp reasoning_summary_requested?(_), do: false

  defp drop_reasoning_summary(body) do
    update_in(body, ["reasoning"], fn reasoning ->
      case reasoning do
        %{} = map ->
          map
          |> Map.delete("summary")
          |> case do
            %{} = cleaned when map_size(cleaned) == 0 -> nil
            cleaned -> cleaned
          end

        other ->
          other
      end
    end)
    |> case do
      %{"reasoning" => nil} = updated -> Map.delete(updated, "reasoning")
      updated -> updated
    end
  end

  defp drop_reasoning_payload(body) do
    Map.delete(body, "reasoning")
  end

  defp build_sse_handler(on_event) do
    fn {:data, data}, {req, resp} ->
      sse_state = Map.get(resp.private, :echs_sse_state, EchsCodex.SSE.new_state())
      {sse_state, events} = EchsCodex.SSE.parse(sse_state, data)

      Enum.each(events, fn event ->
        on_event.(event)
      end)

      resp =
        resp
        |> maybe_append_error_body(data)
        |> then(fn resp ->
          %{resp | private: Map.put(resp.private, :echs_sse_state, sse_state)}
        end)

      {:cont, {req, resp}}
    end
  end

  defp auth_headers do
    auth = EchsCodex.Auth.get_auth()

    if EchsCodex.Auth.auth_source() == :file and
         EchsCodex.Auth.token_expired?(auth.access_token) do
      _ = EchsCodex.Auth.refresh_auth()
    end

    EchsCodex.Auth.get_headers()
  end

  defp do_stream_request(body, headers, on_event, req_opts, summary_requested, opts) do
    auth_refreshed? = Keyword.get(opts, :auth_refreshed?, false)
    summary_dropped? = Keyword.get(opts, :summary_dropped?, false)
    payload_dropped? = Keyword.get(opts, :payload_dropped?, false)
    meta = Keyword.get(opts, :meta, %{})

    request =
      Req.new(
        url: base_url(),
        method: :post,
        headers: headers,
        json: body,
        receive_timeout: :infinity,
        into: build_sse_handler(on_event)
      )
      |> Req.merge(req_opts)

    case Req.request(request) do
      {:ok, %{status: 200}} = result ->
        result

      {:ok, %{status: 401} = resp} ->
        resp_body = extract_error_body(resp)

        if auth_refreshed? do
          {:error, %{status: 401, body: resp_body}}
        else
          case EchsCodex.Auth.refresh_auth() do
            :ok ->
              headers = auth_headers()

              do_stream_request(body, headers, on_event, req_opts, summary_requested,
                auth_refreshed?: true,
                summary_dropped?: summary_dropped?,
                payload_dropped?: payload_dropped?,
                meta: meta
              )

            error ->
              error
          end
        end

      {:ok, %{status: status} = resp} ->
        resp_body = extract_error_body(resp)

        cond do
          summary_requested and not summary_dropped? and status in [400, 403] ->
            Logger.warn(
              "Codex request rejected (status=#{status}); retrying once without reasoning summary model=#{meta[:model]} items=#{meta[:items]} tools=#{meta[:tools]}"
            )

            body = drop_reasoning_summary(body)

            do_stream_request(body, headers, on_event, req_opts, summary_requested,
              auth_refreshed?: auth_refreshed?,
              summary_dropped?: true,
              payload_dropped?: payload_dropped?,
              meta: meta
            )

          summary_dropped? and not payload_dropped? and status in [400, 403] ->
            Logger.warn(
              "Codex request rejected (status=#{status}); retrying once without reasoning payload model=#{meta[:model]} items=#{meta[:items]} tools=#{meta[:tools]}"
            )

            body = drop_reasoning_payload(body)

            do_stream_request(body, headers, on_event, req_opts, summary_requested,
              auth_refreshed?: auth_refreshed?,
              summary_dropped?: true,
              payload_dropped?: true,
              meta: meta
            )

          true ->
            Logger.error(
              "Codex error: status=#{status} body=#{inspect(resp_body)} headers=#{inspect(resp.headers)} model=#{meta[:model]} items=#{meta[:items]} tools=#{meta[:tools]}"
            )

            {:error, %{status: status, body: resp_body}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_compact_request(body, headers, req_opts, opts) do
    auth_refreshed? = Keyword.get(opts, :auth_refreshed?, false)
    meta = Keyword.get(opts, :meta, %{})

    request =
      Req.new(
        url: compact_url(),
        method: :post,
        headers: headers,
        json: body
      )
      |> Req.merge(req_opts)

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{output: body["output"]}}

      {:ok, %{status: 401, body: resp_body}} ->
        if auth_refreshed? do
          {:error, %{status: 401, body: resp_body}}
        else
          case EchsCodex.Auth.refresh_auth() do
            :ok ->
              headers = auth_headers()
              headers = Enum.reject(headers, fn {k, _} -> k == "accept" end)
              headers = [{"accept", "application/json"} | headers]

              do_compact_request(body, headers, req_opts, auth_refreshed?: true, meta: meta)

            error ->
              error
          end
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error(
          "Codex compact error: status=#{status} body=#{inspect(resp_body)} model=#{meta[:model]} items=#{meta[:items]}"
        )

        {:error, %{status: status, body: resp_body}}

      {:error, _} = error ->
        error
    end
  end

  defp base_url do
    env = System.get_env("ECHS_CODEX_BASE_URL") || ""
    env = String.trim(env)
    if env == "", do: @default_base_url, else: env
  end

  defp compact_url do
    env = System.get_env("ECHS_CODEX_COMPACT_URL") || ""
    env = String.trim(env)
    if env == "", do: @default_compact_url, else: env
  end

  defp maybe_append_error_body(%{status: 200} = resp, _chunk), do: resp

  defp maybe_append_error_body(%{status: status} = resp, chunk)
       when is_integer(status) and is_binary(chunk) do
    existing = Map.get(resp.private, :echs_error_body, "")

    next =
      (existing <> chunk)
      |> truncate_bytes(@max_error_body_bytes)

    %{resp | private: Map.put(resp.private, :echs_error_body, next)}
  end

  defp maybe_append_error_body(resp, _chunk), do: resp

  defp extract_error_body(%{body: body, private: private}) do
    body =
      case body do
        %{} = map when map_size(map) > 0 -> map
        binary when is_binary(binary) and binary != "" -> binary
        _ -> Map.get(private, :echs_error_body, body)
      end

    case body do
      binary when is_binary(binary) -> String.trim(binary)
      other -> other
    end
  end

  defp truncate_bytes(binary, max_bytes) when is_binary(binary) and is_integer(max_bytes) do
    if byte_size(binary) > max_bytes do
      binary_part(binary, 0, max_bytes)
    else
      binary
    end
  end
end
