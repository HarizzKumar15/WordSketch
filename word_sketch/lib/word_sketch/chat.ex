defmodule WordSketch.Chat do

  def process_message(user, message, target_word) do
    cond do
      Regex.match?(~r/^[\/\\]word\s+\w+/, message) ->
      [new_word] = Regex.run(~r/^[\/\\]word\s+(\w+)/, message, capture: :all_but_first)
      [ user <> " changed the word.", new_word]
      String.downcase(String.trim(message)) === target_word -> [ user <> " guessed the word.", target_word]
      true -> [ message, target_word]
    end
  end
end
