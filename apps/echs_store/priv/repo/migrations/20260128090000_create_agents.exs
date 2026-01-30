defmodule EchsStore.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :agent_id, :string, primary_key: true

      add :conversation_id,
          references(:conversations,
            column: :conversation_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :status, :string, null: false
      add :goal, :text, null: false
      add :config_json, :text, null: false
      add :tick_seq, :integer, null: false, default: 1

      add :created_at_ms, :integer, null: false
      add :last_activity_at_ms, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:conversation_id])
    create index(:agents, [:status])
    create index(:agents, [:last_activity_at_ms])
  end
end

