defmodule EchsCore.MCP.Connector do
  @moduledoc """
  MCP (Model Context Protocol) stdio connector.

  Launches external MCP servers as subprocesses, negotiates capabilities,
  and bridges their tools into the native tool registry.

  ## Architecture

  Each MCP server connection is managed as a supervised process:
  1. Launch server via stdio (stdin/stdout JSON-RPC)
  2. Send `initialize` to negotiate capabilities
  3. Send `tools/list` to discover available tools
  4. Register tools in the conversation's ToolRegistry
  5. Route tool invocations through the MCP protocol
  6. Handle reconnection for crashes

  ## Wire Protocol

  MCP uses JSON-RPC 2.0 over stdin/stdout:

      -> {"jsonrpc":"2.0","method":"initialize","params":{...},"id":1}
      <- {"jsonrpc":"2.0","result":{...},"id":1}
  """

  use GenServer
  require Logger

  @type server_config :: %{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          capabilities: map()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          port: port() | nil,
          status: :disconnected | :initializing | :ready | :error,
          capabilities: map(),
          tools: [map()],
          pending_requests: %{optional(integer()) => {pid(), reference()}},
          next_id: integer(),
          buffer: binary()
        }

  defstruct [
    :name,
    :command,
    args: [],
    env: [],
    port: nil,
    status: :disconnected,
    capabilities: %{},
    tools: [],
    pending_requests: %{},
    next_id: 1,
    buffer: ""
  ]

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Connect to the MCP server (launch subprocess + initialize).
  """
  @spec connect(GenServer.server()) :: :ok | {:error, term()}
  def connect(connector) do
    GenServer.call(connector, :connect, 30_000)
  end

  @doc """
  List tools available from this MCP server.
  """
  @spec list_tools(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(connector) do
    GenServer.call(connector, :list_tools, 10_000)
  end

  @doc """
  Invoke a tool on the MCP server.
  """
  @spec invoke_tool(GenServer.server(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def invoke_tool(connector, tool_name, arguments) do
    GenServer.call(connector, {:invoke_tool, tool_name, arguments}, 120_000)
  end

  @doc """
  Disconnect from the MCP server.
  """
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(connector) do
    GenServer.call(connector, :disconnect)
  end

  @doc """
  Get the current connection status.
  """
  @spec status(GenServer.server()) :: :disconnected | :initializing | :ready | :error
  def status(connector) do
    GenServer.call(connector, :status)
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, [])
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, %{status: :ready} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:connect, from, state) do
    case launch_server(state) do
      {:ok, port} ->
        state = %{state | port: port, status: :initializing, buffer: ""}

        # Send initialize request
        {id, state} = send_request(state, "initialize", %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "echs",
            "version" => "2.0.0"
          }
        })

        # Store the caller to reply when initialize completes
        state = %{state | pending_requests: Map.put(state.pending_requests, id, {from, nil})}
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | status: :error}}
    end
  end

  def handle_call(:list_tools, _from, %{status: :ready, tools: tools} = state) do
    {:reply, {:ok, tools}, state}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:invoke_tool, tool_name, arguments}, from, %{status: :ready} = state) do
    {id, state} = send_request(state, "tools/call", %{
      "name" => tool_name,
      "arguments" => arguments
    })

    state = %{state | pending_requests: Map.put(state.pending_requests, id, {from, nil})}
    {:noreply, state}
  end

  def handle_call({:invoke_tool, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:disconnect, _from, state) do
    state = close_port(state)
    {:reply, :ok, %{state | status: :disconnected}}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {messages, remaining} = parse_messages(buffer)

    state = %{state | buffer: remaining}

    state =
      Enum.reduce(messages, state, fn msg, acc ->
        handle_jsonrpc(msg, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("MCP server #{state.name} exited with code #{code}")
    {:noreply, %{state | port: nil, status: :disconnected}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state)
  end

  # -------------------------------------------------------------------
  # JSON-RPC handling
  # -------------------------------------------------------------------

  defp handle_jsonrpc(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {{from, _}, remaining} ->
        state = %{state | pending_requests: remaining}

        cond do
          # Initialize response
          state.status == :initializing ->
            capabilities = Map.get(result, "capabilities", %{})
            state = %{state | status: :ready, capabilities: capabilities}

            # Fetch tools
            {tool_id, state} = send_request(state, "tools/list", %{})
            state = %{state | pending_requests: Map.put(state.pending_requests, tool_id, {:tools_list, nil})}

            GenServer.reply(from, :ok)
            state

          true ->
            GenServer.reply(from, {:ok, result})
            state
        end
    end
  end

  defp handle_jsonrpc(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {{from, _}, remaining} ->
        state = %{state | pending_requests: remaining}

        if is_tuple(from) and elem(from, 0) == :tools_list do
          Logger.warning("MCP tools/list failed: #{inspect(error)}")
          state
        else
          GenServer.reply(from, {:error, error})
          state
        end
    end
  end

  # tools/list response
  defp handle_jsonrpc(%{"id" => id} = msg, state) when is_map_key(msg, "result") do
    case Map.pop(state.pending_requests, id) do
      {{:tools_list, _}, remaining} ->
        tools = get_in(msg, ["result", "tools"]) || []
        Logger.info("MCP server #{state.name}: discovered #{length(tools)} tools")
        %{state | tools: tools, pending_requests: remaining}

      _ ->
        state
    end
  end

  defp handle_jsonrpc(_msg, state), do: state

  # -------------------------------------------------------------------
  # Port management
  # -------------------------------------------------------------------

  defp launch_server(state) do
    cmd = state.command
    args = state.args

    try do
      env = Enum.map(state.env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      port =
        Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: args,
          env: env
        ])

      {:ok, port}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp send_request(state, method, params) do
    id = state.next_id

    msg = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => id
    })

    if state.port do
      Port.command(state.port, msg <> "\n")
    end

    {id, %{state | next_id: id + 1}}
  end

  defp parse_messages(buffer) do
    # Split on newlines and try to parse each as JSON
    lines = String.split(buffer, "\n")
    {last, complete} = List.pop_at(lines, -1)

    messages =
      complete
      |> Enum.flat_map(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, msg} -> [msg]
          _ -> []
        end
      end)

    {messages, last || ""}
  end

  defp close_port(%{port: nil} = state), do: state

  defp close_port(%{port: port} = state) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    %{state | port: nil}
  end
end
