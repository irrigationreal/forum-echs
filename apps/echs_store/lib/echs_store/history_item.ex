defmodule EchsStore.HistoryItem do
  @moduledoc false

  use Ecto.Schema

  schema "history_items" do
    field(:thread_id, :string)
    field(:idx, :integer)
    field(:message_id, :string)

    field(:item, :map)

    timestamps(type: :utc_datetime_usec)
  end
end
