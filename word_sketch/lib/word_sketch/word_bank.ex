defmodule WordSketch.WordBank do
  @moduledoc """
  Fetches random words from the database for word selection.
  Falls back to a hardcoded list if the database is empty.
  """

  alias WordSketch.Repo
  alias WordSketch.Words.Word
  import Ecto.Query

  @fallback_words ~w(
    apple house bicycle guitar elephant mountain rainbow
    umbrella airplane butterfly castle dragon flower garden
    helicopter island jungle knight lighthouse mushroom
    notebook ocean penguin queen robot sunflower telescope
    unicorn volcano waterfall xylophone zebra anchor bridge
    camera diamond engine feather globe hammer ice jacket
    lantern mirror needle orange piano rocket sword tree
  )

  @doc """
  Returns `count` random words. Tries the database first;
  falls back to a hardcoded word list if the words table is empty.
  """
  @spec get_random_words(pos_integer()) :: [String.t()]
  def get_random_words(count \\ 3) do
    db_words =
      Repo.all(from w in Word, order_by: fragment("RANDOM()"), limit: ^count)
      |> Enum.map(& &1.word)

    case db_words do
      [] -> Enum.take_random(@fallback_words, count)
      words -> words
    end
  end
end
