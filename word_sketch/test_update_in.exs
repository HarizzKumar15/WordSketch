state = %{players: %{"hari" => %{score: 0, guessed: false}, "jeff" => %{score: 0, guessed: false}}}
user_id = "hari"
drawer = "jeff"
guesser_points = 234
drawer_points = 100

players = update_in(state.players[user_id], fn p -> 
  %{p | score: p.score + guesser_points, guessed: true} 
end)
IO.inspect(players, label: "After first update")
players = update_in(players[drawer], fn p -> 
  %{p | score: p.score + drawer_points} 
end)

IO.inspect(players)
