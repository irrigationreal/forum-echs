defmodule EchsCodex.Responses do
  @moduledoc """
  Handles calls to the Codex responses API endpoint.
  Supports streaming SSE responses.
  """

  require Logger

  @base_url "https://codex.ppflix.net/v1/responses"
  @compact_url "https://codex.ppflix.net/v1/responses/compact"

  @default_model "gpt-5.2-codex"

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
  """
  def stream_response(opts) do
    model = Keyword.get(opts, :model, @default_model)
    instructions = Keyword.fetch!(opts, :instructions)
    input = Keyword.get(opts, :input, [])
    tools = Keyword.get(opts, :tools, [])
    reasoning = Keyword.get(opts, :reasoning, "medium")
    on_event = Keyword.fetch!(opts, :on_event)
    parallel_tool_calls = Keyword.get(opts, :parallel_tool_calls, true)

    reasoning_payload = build_reasoning_payload(reasoning)

    body =
      %{
        "model" => model,
        "instructions" => instructions,
        "input" => input,
        "tools" => tools,
        "tool_choice" => "auto",
        "parallel_tool_calls" => parallel_tool_calls,
        "store" => false,
        "stream" => true,
        "include" => []
      }
      |> maybe_put("reasoning", reasoning_payload)

    headers = auth_headers()

    # Use Req with streaming
    request =
      Req.new(
        url: @base_url,
        method: :post,
        headers: headers,
        json: body,
        receive_timeout: :infinity,
        into: build_sse_handler(on_event)
      )

    Logger.debug(fn ->
      "Codex request to #{@base_url} model=#{model} items=#{length(input)} tools=#{length(tools)}"
    end)

    case Req.request(request) do
      {:ok, %{status: 200}} = result ->
        result

      {:ok, %{status: 401}} ->
        # Try refresh and retry once
        case EchsCodex.Auth.refresh_auth() do
          :ok ->
            headers = auth_headers()

            request =
              Req.new(
                url: @base_url,
                method: :post,
                headers: headers,
                json: body,
                receive_timeout: :infinity,
                into: build_sse_handler(on_event)
              )

            Req.request(request)

          error ->
            error
        end

      {:ok, %{status: status, body: resp_body} = resp} ->
        Logger.error(
          "Codex error: status=#{status} body=#{inspect(resp_body)} headers=#{inspect(resp.headers)}"
        )

        {:error, %{status: status, body: resp_body}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Compact conversation history via the compaction endpoint.
  """
  def compact(opts) do
    model = Keyword.get(opts, :model, @default_model)
    instructions = Keyword.fetch!(opts, :instructions)
    input = Keyword.fetch!(opts, :input)

    body = %{
      "model" => model,
      "instructions" => instructions,
      "input" => input
    }

    headers = auth_headers()
    # Remove accept: text/event-stream for non-streaming endpoint
    headers = Enum.reject(headers, fn {k, _} -> k == "accept" end)
    headers = [{"accept", "application/json"} | headers]

    case Req.post(@compact_url, headers: headers, json: body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{output: body["output"]}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, _} = error ->
        error
    end
  end

  defp build_reasoning_payload(reasoning) do
    case reasoning do
      nil ->
        %{}

      "" ->
        %{}

      value when is_binary(value) ->
        summary = if value == "none", do: "none", else: "auto"
        %{"effort" => value, "summary" => summary}

      _ ->
        %{}
    end
  end

  defp maybe_put(map, _key, payload) when map_size(payload) == 0, do: map
  defp maybe_put(map, key, payload), do: Map.put(map, key, payload)

  defp build_sse_handler(on_event) do
    fn {:data, data}, {req, resp} ->
      sse_state = Map.get(resp.private, :echs_sse_state, EchsCodex.SSE.new_state())
      {sse_state, events} = EchsCodex.SSE.parse(sse_state, data)

      Enum.each(events, fn event ->
        on_event.(event)
      end)

      resp = %{resp | private: Map.put(resp.private, :echs_sse_state, sse_state)}
      {:cont, {req, resp}}
    end
  end

  defp auth_headers do
    auth = EchsCodex.Auth.get_auth()

    if EchsCodex.Auth.token_expired?(auth.access_token) do
      _ = EchsCodex.Auth.refresh_auth()
    end

    EchsCodex.Auth.get_headers()
  end
end
