defmodule WordSketch.Repo do
  use Ecto.Repo,
    otp_app: :word_sketch,
    adapter: Ecto.Adapters.Postgres
end
