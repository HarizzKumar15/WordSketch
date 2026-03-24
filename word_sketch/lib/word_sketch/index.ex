defmodule WordSketch.Index do

  # interacts with the game schema ig
  alias WordSketch.Repo
  alias WordSketch.Games.Game
  alias WordSketch.Users.User

  def create_room(user_name) do
    room_code = generate_unique_room_code()

    changeset_game = Game.changeset(%Game{}, %{
      room_code: room_code,
      creator_name: user_name,
      status: "active"
    })

    changeset_user = User.changeset(%User{}, %{
      username: user_name,
      room_code: room_code,
      role: "creator"
    })

    case Repo.insert(changeset_game) do
      {:ok, game} ->
        case Repo.insert(changeset_user) do
          {:ok, user} ->
            {:ok, %{room_id: game.id, room_code: game.room_code, creator_name: user_name, user_id: user.id , username: user.username, role: user.role}}
          {:error, changeset} ->
            {:error, changeset}
        end
      {:error, changeset_game} ->
        {:error, changeset_game}
    end

  end

  defp generate_unique_room_code do
    room_code = :crypto.strong_rand_bytes(4) |> Base.encode16() |> binary_part(0, 6)
    if Repo.get_by(Game, room_code: room_code) do
      generate_unique_room_code()
    else
      room_code
    end
  end

end
