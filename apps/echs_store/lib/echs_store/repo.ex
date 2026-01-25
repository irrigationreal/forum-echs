defmodule EchsStore.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :echs_store,
    adapter: Ecto.Adapters.SQLite3
end
