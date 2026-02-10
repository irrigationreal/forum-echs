defmodule EchsCli.Tui.StdoutGuard do
  @moduledoc """
  Prevents stdout/stderr writes from corrupting the TUI's alternate screen buffer.

  Three-layer protection:
  1. Swaps the `:user` and `:standard_error` process registrations with I/O sinks
  2. Walks all existing BEAM processes and redirects group leaders from the
     original stdout/stderr PIDs to the sinks
  3. Replaces the default Erlang logger handler with a file handler and a
     ring-buffer handler for in-TUI log access

  Call `activate/0` before `Ratatouille.run/2` and `deactivate/0` after (in a
  try/after block) to ensure cleanup even on crash.
  """

  use GenServer

  alias EchsCli.Tui.StdoutGuard.{IoSink, RingHandler}

  @ring_size 200
  @default_log_file "tmp/echs_tui.log"

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def activate, do: GenServer.call(__MODULE__, :activate)
  def deactivate, do: GenServer.call(__MODULE__, :deactivate)
  def recent_logs, do: GenServer.call(__MODULE__, :recent_logs)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    log_file = Keyword.get(opts, :log_file, @default_log_file)

    {:ok, %{
      active?: false,
      log_file: log_file,
      original_user: nil,
      original_stderr: nil,
      user_sink: nil,
      stderr_sink: nil,
      ring: :queue.new(),
      ring_size: 0
    }}
  end

  @impl true
  def handle_call(:activate, _from, %{active?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:activate, _from, state) do
    # 1. Capture original I/O processes
    original_user = Process.whereis(:user)
    original_stderr = Process.whereis(:standard_error)

    # 2. Start sink processes
    {:ok, user_sink} = IoSink.start_link()
    {:ok, stderr_sink} = IoSink.start_link()

    # 3. Swap process registrations
    if original_user do
      Process.unregister(:user)
      Process.register(user_sink, :user)
    end

    if original_stderr do
      Process.unregister(:standard_error)
      Process.register(stderr_sink, :standard_error)
    end

    # 4. Walk all processes and redirect group leaders pointing at the originals
    redirect_group_leaders(original_user, user_sink)
    if original_stderr, do: redirect_group_leaders(original_stderr, stderr_sink)

    # 5. Swap logger handlers: remove console, add file + ring
    :logger.remove_handler(:default)

    log_dir = Path.dirname(state.log_file)
    File.mkdir_p!(log_dir)

    :logger.add_handler(:tui_file, :logger_std_h, %{
      config: %{type: {:file, to_charlist(state.log_file)}},
      level: :all
    })

    :logger.add_handler(:tui_ring, RingHandler, %{
      config: %{pid: self()},
      level: :all
    })

    {:reply, :ok, %{state |
      active?: true,
      original_user: original_user,
      original_stderr: original_stderr,
      user_sink: user_sink,
      stderr_sink: stderr_sink
    }}
  end

  def handle_call(:deactivate, _from, %{active?: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:deactivate, _from, state) do
    do_deactivate(state)
    {:reply, :ok, %{state | active?: false}}
  end

  def handle_call(:recent_logs, _from, state) do
    {:reply, :queue.to_list(state.ring), state}
  end

  @impl true
  def handle_info({:log_event, text}, state) do
    {ring, size} =
      if state.ring_size >= @ring_size do
        {_dropped, q} = :queue.out(state.ring)
        {:queue.in(text, q), state.ring_size}
      else
        {:queue.in(text, state.ring), state.ring_size + 1}
      end

    {:noreply, %{state | ring: ring, ring_size: size}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{active?: true} = state) do
    do_deactivate(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Internal ---

  defp do_deactivate(state) do
    # Restore group leaders
    if state.original_user do
      redirect_group_leaders(state.user_sink, state.original_user)
    end

    if state.original_stderr do
      redirect_group_leaders(state.stderr_sink, state.original_stderr)
    end

    # Restore process registrations
    if state.original_user && Process.alive?(state.original_user) do
      if Process.whereis(:user) == state.user_sink do
        Process.unregister(:user)
        Process.register(state.original_user, :user)
      end
    end

    if state.original_stderr && Process.alive?(state.original_stderr) do
      if Process.whereis(:standard_error) == state.stderr_sink do
        Process.unregister(:standard_error)
        Process.register(state.original_stderr, :standard_error)
      end
    end

    # Stop sinks
    if state.user_sink && Process.alive?(state.user_sink), do: GenServer.stop(state.user_sink, :normal)
    if state.stderr_sink && Process.alive?(state.stderr_sink), do: GenServer.stop(state.stderr_sink, :normal)

    # Restore logger handlers
    :logger.remove_handler(:tui_ring)
    :logger.remove_handler(:tui_file)
    :logger.add_handler(:default, :logger_std_h, %{config: %{type: :standard_io}})
  end

  defp redirect_group_leaders(from_pid, to_pid) when is_pid(from_pid) and is_pid(to_pid) do
    Process.list()
    |> Enum.each(fn pid ->
      try do
        case Process.info(pid, :group_leader) do
          {:group_leader, ^from_pid} ->
            Process.group_leader(pid, to_pid)
          _ ->
            :ok
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end

  defp redirect_group_leaders(_, _), do: :ok
end
