defmodule EchsStore.Migrator do
  @moduledoc false

  alias EchsStore.Repo

  @spec migrate() :: :ok | {:error, term()}
  def migrate do
    ensure_db_dir()

    path = Application.app_dir(:echs_store, "priv/repo/migrations")

    try do
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, path, :up, all: true)
      end)

      :ok
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp ensure_db_dir do
    db = Repo.config()[:database]

    if is_binary(db) and db not in [":memory:", ""] do
      _ = db |> Path.dirname() |> File.mkdir_p()
    end
  end
end
