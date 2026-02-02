defmodule EchsServer.AutoResume do
  @moduledoc false

  require Logger

  def start do
    if enabled?() do
      Task.start(fn -> restore_threads() end)
    else
      :ok
    end
  end

  defp restore_threads do
    if Code.ensure_loaded?(EchsStore) and EchsStore.enabled?() do
      limit = auto_resume_limit()
      threads = EchsStore.list_threads(limit: limit)

      Enum.each(threads, fn thread ->
        case EchsCore.StoreRestore.restore_thread(thread.thread_id) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning(
              "Auto-resume failed thread_id=#{thread.thread_id} reason=#{inspect(reason)}"
            )
        end
      end)
    else
      Logger.info("Auto-resume skipped: store unavailable")
    end
  end

  defp enabled? do
    case System.get_env("ECHS_AUTO_RESUME") do
      nil -> true
      value -> value in ["1", "true", "yes", "on"]
    end
  end

  defp auto_resume_limit do
    case System.get_env("ECHS_AUTO_RESUME_LIMIT") do
      nil -> 10
      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> 10
    end
  end
end
end
