defmodule WordSketch.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :room_code, :string
    field :role, :string, default: "player"
    field :score, :integer, default: 0
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :room_code, :role, :score])
    |> validate_required([:username, :room_code, :role, :score])
  end
end
