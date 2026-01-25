defmodule EchsStore.Message do
  @moduledoc false

  use Ecto.Schema

  schema "messages" do
    field(:thread_id, :string)
    field(:message_id, :string)
    field(:status, :string)

    field(:enqueued_at_ms, :integer)
    field(:started_at_ms, :integer)
    field(:completed_at_ms, :integer)

    field(:history_start, :integer)
    field(:history_end, :integer)

    field(:error, :string)

    # JSON payload of the original enqueue request. Used for durable replay of
    # queued messages on resume. The shape is internal and may evolve.
    field(:request_json, :string)

    timestamps(type: :utc_datetime_usec)
  end
end
