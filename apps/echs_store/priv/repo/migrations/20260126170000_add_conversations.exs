defmodule EchsStore.Repo.Migrations.AddConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :conversation_id, :string, primary_key: true
      add :active_thread_id, :string

      add :created_at_ms, :integer, null: false
      add :last_activity_at_ms, :integer, null: false

      add :model, :string, null: false
      add :reasoning, :string, null: false
      add :cwd, :string, null: false
      add :instructions, :text, null: false
      add :tools_json, :text, null: false
      add :coordination_mode, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:last_activity_at_ms])
    create index(:conversations, [:active_thread_id])

    alter table(:threads) do
      add :conversation_id, references(:conversations, column: :conversation_id, type: :string, on_delete: :nilify_all)
    end

    create index(:threads, [:conversation_id])
  end
end
