# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     WordSketch.Repo.insert!(%WordSketch.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias WordSketch.Repo
alias WordSketch.Words.Word

File.stream!("priv/repo/myWords.txt")
|> Stream.map(&String.trim/1)
|> Enum.each(fn word ->
  cleaned_word = String.replace(word, "-", " ")
  %Word{}
  |> Word.changeset(%{word: cleaned_word})
  |> Repo.insert!()
end)
