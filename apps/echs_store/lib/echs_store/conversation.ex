defmodule EchsStore.Conversation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:conversation_id, :string, autogenerate: false}

  schema "conversations" do
    field(:active_thread_id, :string)
    field(:created_at_ms, :integer)
    field(:last_activity_at_ms, :integer)
    field(:model, :string)
    field(:reasoning, :string)
    field(:cwd, :string)
    field(:instructions, :string)
    field(:tools_json, :string)
    field(:coordination_mode, :string)

    timestamps(type: :utc_datetime_usec)
  end
end
