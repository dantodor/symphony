defmodule SymphonyV2.Repo do
  use Ecto.Repo,
    otp_app: :symphony_v2,
    adapter: Ecto.Adapters.Postgres
end
