defmodule EchsCli.Tui.StdoutGuard.IoSink do
  @moduledoc """
  A GenServer that implements the Erlang I/O protocol.
  All write requests are silently discarded to prevent output from
  corrupting the TUI's alternate screen buffer.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_info({:io_request, from, ref, request}, state) do
    reply = handle_io_request(request)
    send(from, {:io_reply, ref, reply})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_io_request({:put_chars, _encoding, chars}) when is_binary(chars), do: :ok
  defp handle_io_request({:put_chars, _encoding, chars}) when is_list(chars), do: :ok
  defp handle_io_request({:put_chars, chars}) when is_binary(chars), do: :ok
  defp handle_io_request({:put_chars, chars}) when is_list(chars), do: :ok
  defp handle_io_request({:put_chars, _encoding, mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args), do: :ok
  defp handle_io_request({:get_chars, _prompt, _count}), do: {:error, :enotsup}
  defp handle_io_request({:get_chars, _encoding, _prompt, _count}), do: {:error, :enotsup}
  defp handle_io_request({:get_line, _prompt}), do: {:error, :enotsup}
  defp handle_io_request({:get_line, _encoding, _prompt}), do: {:error, :enotsup}
  defp handle_io_request({:get_until, _prompt, _mod, _fun, _args}), do: {:error, :enotsup}
  defp handle_io_request({:get_until, _encoding, _prompt, _mod, _fun, _args}), do: {:error, :enotsup}
  defp handle_io_request({:setopts, _opts}), do: :ok
  defp handle_io_request(:getopts), do: {:ok, []}
  defp handle_io_request({:get_geometry, _}), do: {:error, :enotsup}

  defp handle_io_request({:requests, requests}) when is_list(requests) do
    Enum.each(requests, &handle_io_request/1)
    :ok
  end

  defp handle_io_request(_), do: {:error, :request}
end
