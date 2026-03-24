defmodule WordSketchWeb.IndexController do
  use WordSketchWeb, :controller
  alias WordSketch.Index


  def index(conn, _params) do
    render(conn, :index , layout: false)
  end

  def create_room(conn, %{"creator_name" => creator_name}) do
    case Index.create_room(creator_name) do
      {:ok, %{room_id: game_id, room_code: room_code, creator_name: user_name, user_id: user_id , username: username, role: role}} ->
        json(conn, %{room_id: game_id, room_code: room_code, creator_name: user_name, user_id: user_id , username: username, role: role})
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset.errors})
    end
  end

end
