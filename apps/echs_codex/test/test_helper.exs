# Ensure the :req application is started so that Req.Test.Ownership is available
# for tests that use Req.Test stubs/expectations (e.g., ResponsesRetryTest).
Application.ensure_all_started(:req)

# Start the CircuitBreaker GenServer so that ETS-backed circuit state works
# in tests run with --no-start.
case GenServer.whereis(EchsCodex.CircuitBreaker) do
  nil -> EchsCodex.CircuitBreaker.start_link()
  _pid -> :ok
end

ExUnit.start()
