defmodule EchsStore.Repo.Migrations.DropAgents do
  use Ecto.Migration

  def change do
    drop_if_exists table(:agents)
  end
end

