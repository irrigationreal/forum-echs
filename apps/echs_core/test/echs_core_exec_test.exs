defmodule EchsCore.Tools.ExecTest do
  use ExUnit.Case, async: true

  alias EchsCore.Tools.Exec

  setup do
    name = {:global, {__MODULE__, make_ref()}}
    {:ok, _pid} = start_supervised({Exec, name: name})
    %{exec: name}
  end

  test "buffers output produced while not polling", %{exec: exec} do
    # Force an early return while the command is still running.
    {:ok, first} =
      Exec.exec_command(exec,
        cmd: ~s(printf "a"; sleep 0.3; printf "b"; sleep 0.3; printf "c"),
        shell: "/bin/bash",
        login: false,
        yield_time_ms: 10
      )

    assert first =~ "Process running with session ID"
    assert first =~ "Output:\na"

    [_, session_id] =
      Regex.run(~r/Process running with session ID (\d+)/, first) ||
        flunk("expected a session id in output:\n#{first}")

    # Let the command finish and emit output while we are not polling.
    Process.sleep(700)

    {:ok, second} =
      Exec.write_stdin(exec,
        session_id: session_id,
        chars: "",
        yield_time_ms: 10
      )

    # We should see the remainder ("bc") even though it happened while idle.
    assert second =~ "Process exited with code 0"
    assert second =~ "Output:\nbc"
  end

  test "kill_session removes a running session", %{exec: exec} do
    {:ok, first} =
      Exec.exec_command(exec,
        cmd: ~s(sleep 5),
        shell: "/bin/bash",
        login: false,
        yield_time_ms: 10
      )

    [_, session_id] =
      Regex.run(~r/Process running with session ID (\d+)/, first) ||
        flunk("expected a session id in output:\n#{first}")

    assert :ok = Exec.kill_session(exec, session_id)
    assert {:error, _} = Exec.write_stdin(exec, session_id: session_id, chars: "")
  end

  test "returns quickly when process exits before yield_time", %{exec: exec} do
    {:ok, result} =
      Exec.exec_command(exec,
        cmd: "true",
        shell: "/bin/bash",
        login: false,
        yield_time_ms: 5_000
      )

    [_, wall_time] =
      Regex.run(~r/Wall time: ([0-9.]+) seconds/, result) ||
        flunk("expected wall time in output:\n#{result}")

    wall_time = String.to_float(wall_time)
    assert wall_time < 1.0
  end
end
