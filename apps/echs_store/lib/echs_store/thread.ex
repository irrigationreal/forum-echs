defmodule EchsStore.Thread do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:thread_id, :string, autogenerate: false}

  schema "threads" do
    field(:conversation_id, :string)
    field(:parent_thread_id, :string)
    field(:created_at_ms, :integer)
    field(:last_activity_at_ms, :integer)

    field(:model, :string)
    field(:reasoning, :string)
    field(:cwd, :string)
    field(:instructions, :string)

    # Stored as JSON text because the tool surface can include lists and mixed
    # shapes that do not fit Ecto's :map type well.
    field(:tools_json, :string)

    field(:coordination_mode, :string)

    # How many history items have been persisted (also the next idx to assign).
    field(:history_count, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end
end
