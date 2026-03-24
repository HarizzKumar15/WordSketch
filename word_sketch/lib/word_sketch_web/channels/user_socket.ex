defmodule WordSketchWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", WordSketchWeb.RoomChannel

  @impl true
  def connect(params, socket, _connect_info) do
    username = Map.get(params, "username", "Anonymous")
    room_code = Map.get(params, "roomCode", "")
    player_id = Map.get(params, "player_id")

    if player_id do
      {:ok, assign(socket, %{username: username, roomCode: room_code, player_id: player_id})}
    else
      # Reject connection if no player_id provided
      {:error, %{reason: "missing_player_id"}}
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.player_id}"

  def code(socket), do: socket.assigns.roomCode
end
