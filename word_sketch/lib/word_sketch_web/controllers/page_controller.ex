defmodule WordSketchWeb.PageController do
  use WordSketchWeb, :controller
  def room(conn, %{"roomCode" => roomCode}) do
      render(conn, :room, roomCode: roomCode, layout: false)
  end


end
