defmodule WordSketch.Words.Word do
  use Ecto.Schema
  import Ecto.Changeset

  schema "words" do
    field :word, :string
  end

  def changeset(word, attrs) do
    word
    |> cast(attrs, [:word])
    |> validate_required([:word])
  end
end
