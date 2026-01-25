defmodule EchsStore.Repo.Migrations.CreateStoreTables do
  use Ecto.Migration

  def change do
    create table(:threads, primary_key: false) do
      add :thread_id, :string, primary_key: true
      add :parent_thread_id, :string

      add :created_at_ms, :integer, null: false
      add :last_activity_at_ms, :integer, null: false

      add :model, :string, null: false
      add :reasoning, :string, null: false
      add :cwd, :string, null: false
      add :instructions, :text, null: false
      add :tools_json, :text, null: false
      add :coordination_mode, :string, null: false

      add :history_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threads, [:last_activity_at_ms])

    create table(:messages) do
      add :thread_id, references(:threads, column: :thread_id, type: :string, on_delete: :delete_all),
        null: false

      add :message_id, :string, null: false
      add :status, :string, null: false

      add :enqueued_at_ms, :integer
      add :started_at_ms, :integer
      add :completed_at_ms, :integer

      add :history_start, :integer
      add :history_end, :integer

      add :error, :text

      add :request_json, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:messages, [:thread_id, :message_id])
    create index(:messages, [:thread_id, :status])
    create index(:messages, [:thread_id, :completed_at_ms])

    create table(:history_items) do
      add :thread_id, references(:threads, column: :thread_id, type: :string, on_delete: :delete_all),
        null: false

      add :idx, :integer, null: false
      add :message_id, :string
      add :item, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:history_items, [:thread_id, :idx])
    create index(:history_items, [:thread_id, :message_id])
  end
end

