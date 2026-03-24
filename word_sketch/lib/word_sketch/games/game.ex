defmodule WordSketch.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset

  schema "games" do
    field :room_code, :string
    field :creator_name, :string
    belongs_to :creator, WordSketch.Users.User, foreign_key: :creator_id
    field :status, :string, default: "active"
    #belongs_to :word, WordSketch.Words.Word
    timestamps()
  end

  def changeset(game, attrs) do
    game
    |> cast(attrs, [:room_code, :creator_id, :status, :creator_name])
    |> validate_required([:room_code, :creator_name])
    |> unique_constraint(:room_code)
  end
end
