defmodule WordSketchWeb.RoomChannel do
  @moduledoc """
  Phoenix Channel for room-level real-time communication.

  This module is a thin transport layer. It does NOT contain game logic.
  All game state mutations are delegated to `WordSketch.GameServer`.

  ## Responsibilities

  1. On `join/3` — ensure a GameServer exists, register the player, subscribe
     to the GameServer's PubSub topic, and push the current game state.
  2. On client events (`start_game`, `select_word`, `submit_guess`) — delegate
     to GameServer and reply with the result.
  3. On drawing events (`draw`, `draw_batch`, `clear_canvas`) — broadcast
     directly to all clients (bypass GameServer for performance).
  4. On PubSub messages from GameServer — relay to the channel as pushes/broadcasts.
  5. On `terminate/2` — remove the player from GameServer.

  ## PubSub wiring

  GameServer broadcasts on topic `"game:<room_code>"` with messages shaped as
  `{event_name, payload}`. This channel subscribes in `join/3` and relays
  each message via `handle_info/2`.
  """

  use Phoenix.Channel
  require Logger

  alias WordSketch.GameServer
  alias WordSketch.Games.Game
  alias WordSketch.Users.User
  alias WordSketch.Repo
  import Ecto.Query

  # ── Join ─────────────────────────────────────────────────────────────────

  @doc """
  Join a room channel. The topic must match `"room:<room_code>"`.

  On join we:
  1. Ensure a GameServer process is running for this room.
  2. Register the player in the GameServer (idempotent).
  3. Subscribe to the GameServer's PubSub topic so we receive
     game events (timer ticks, turn changes, etc.).
  4. Push the current game state snapshot to the joining client.
  """
  @impl true
  def join("room:" <> room_code, _payload, socket) do
    username = socket.assigns[:username] || "Anonymous"
    player_id = socket.assigns[:player_id]

    unless player_id do
      {:error, %{reason: "missing_player_id"}}
    else
      # Ensure a GameServer is alive for this room
      case GameServer.ensure_started(room_code) do
        {:ok, _pid} ->
          # Register the player in the game state (handles reconnect automatically)
          GameServer.add_player(room_code, player_id, username)

          # Subscribe this channel process to GameServer broadcasts
          Phoenix.PubSub.subscribe(WordSketch.PubSub, "game:" <> room_code)

          socket =
            socket
            |> assign(:room_code, room_code)
            |> assign(:username, username)
            |> assign(:player_id, player_id)

          # Send the current state snapshot so late joiners / reconnectors are in sync
          send(self(), :after_join)

          {:ok, socket}

        {:error, reason} ->
          Logger.error("Failed to start GameServer for room #{room_code}: #{inspect(reason)}")
          {:error, %{reason: "failed_to_start_game"}}
      end
    end
  end

  # ── Client → Server events ──────────────────────────────────────────────

  @doc "Relay drawing data directly to all other clients (no GameServer)."
  @impl true
  def handle_in("draw", payload, socket) do
    broadcast_from!(socket, "draw", payload)
    {:noreply, socket}
  end

  def handle_in("draw_batch", %{"strokes" => _strokes} = payload, socket) do
    broadcast_from!(socket, "draw_batch", payload)
    {:noreply, socket}
  end

  def handle_in("clear_canvas", payload, socket) do
    broadcast!(socket, "clear_canvas", payload)
    {:noreply, socket}
  end

  def handle_in("start_game", payload, socket) do
    room_code = socket.assigns.room_code
    rounds = Map.get(payload, "rounds", 3)

    case GameServer.start_game(room_code, rounds) do
      :ok ->
        {:reply, {:ok, %{status: "started"}}, socket}

      {:error, :not_enough_players} ->
        {:reply, {:error, %{reason: "not_enough_players"}}, socket}

      {:error, :game_already_started} ->
        {:reply, {:error, %{reason: "game_already_started"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("return_to_lobby", _payload, socket) do
    room_code = socket.assigns.room_code

    case GameServer.return_to_lobby(room_code) do
      :ok ->
        {:reply, {:ok, %{status: "in_lobby"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("select_word", %{"word" => word}, socket) do
    room_code = socket.assigns.room_code

    case GameServer.select_word(room_code, word) do
      :ok ->
        {:reply, {:ok, %{status: "word_selected"}}, socket}

      {:error, :invalid_word_choice} ->
        {:reply, {:error, %{reason: "invalid_word_choice"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("submit_guess", %{"guess" => guess}, socket) do
    room_code = socket.assigns.room_code
    player_id = socket.assigns.player_id

    case GameServer.submit_guess(room_code, player_id, guess) do
      {:correct, points} ->
        {:reply, {:ok, %{result: "correct", points: points}}, socket}

      :wrong ->
        {:reply, {:ok, %{result: "wrong"}}, socket}

      :already_guessed ->
        {:reply, {:ok, %{result: "already_guessed"}}, socket}

      :is_drawer ->
        {:reply, {:error, %{reason: "you_are_the_drawer"}}, socket}

      {:error, :not_in_drawing_phase} ->
        {:reply, {:error, %{reason: "not_in_drawing_phase"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("check_room", %{"room_code" => room_code, "userName" => user_name}, socket) do
    exists = check_room_exists(room_code)

    if exists do
      changeset = User.changeset(%User{}, %{
        username: user_name,
        room_code: room_code,
        role: "player"
      })
      Repo.insert(changeset)
    end

    {:reply, {:ok, %{exists: exists}}, socket}
  end

  # ── GameServer PubSub → Client ──────────────────────────────────────────

  @doc """
  Relay GameServer PubSub events to connected clients.

  The GameServer broadcasts tuples like `{"turn_started", %{...}}` on the
  `"game:<room_code>"` PubSub topic. We pattern-match each event and
  push/broadcast it to connected clients.

  Special handling for `drawer_word`: only pushed to the drawer, not broadcast.
  Special handling for `word_select`: choices are only pushed to the drawer.
  """
  @impl true

  # Send the word only to the current drawer
  def handle_info({"drawer_word", %{word: word, drawer: drawer}}, socket) do
    if socket.assigns.player_id == drawer do
      push(socket, "drawer_word", %{word: word})
    end
    {:noreply, socket}
  end

  # Send word choices only to the drawer; other players get a "waiting" message
  def handle_info({"word_select", %{drawer: drawer, choices: choices, round: round}}, socket) do
    if socket.assigns.player_id == drawer do
      push(socket, "word_select", %{drawer: drawer, choices: choices, round: round})
    else
      push(socket, "word_select", %{drawer: drawer, choices: [], round: round})
    end
    {:noreply, socket}
  end

  # Broadcast these events to all clients in the channel
  def handle_info({"game_started", payload}, socket) do
    push(socket, "game_started", payload)
    {:noreply, socket}
  end

  def handle_info({"returned_to_lobby", payload}, socket) do
    push(socket, "returned_to_lobby", payload)
    {:noreply, socket}
  end

  def handle_info({"turn_started", payload}, socket) do
    push(socket, "turn_started", payload)
    {:noreply, socket}
  end

  def handle_info({"correct_guess", payload}, socket) do
    push(socket, "correct_guess", payload)
    {:noreply, socket}
  end

  def handle_info({"chat_message", payload}, socket) do
    push(socket, "chat_message", payload)
    {:noreply, socket}
  end

  def handle_info({"turn_ended", payload}, socket) do
    push(socket, "turn_ended", payload)
    {:noreply, socket}
  end

  def handle_info({"game_over", payload}, socket) do
    push(socket, "game_over", payload)
    {:noreply, socket}
  end

  def handle_info({"timer_tick", payload}, socket) do
    push(socket, "timer_tick", payload)
    {:noreply, socket}
  end

  # Progressive word reveal — push updated hint only to guessers (not the drawer)
  def handle_info({"word_update", payload}, socket) do
    push(socket, "word_update", payload)
    {:noreply, socket}
  end

  # Letter reveal feedback — frontend animates the newly revealed letter
  def handle_info({"hint_revealed", payload}, socket) do
    push(socket, "hint_revealed", payload)
    {:noreply, socket}
  end

  def handle_info({"player_joined", payload}, socket) do
    push(socket, "player_joined", payload)
    {:noreply, socket}
  end

  def handle_info({"player_left", payload}, socket) do
    push(socket, "player_left", payload)
    {:noreply, socket}
  end

  # Push current game state snapshot to the client after joining
  def handle_info(:after_join, socket) do
    room_code = socket.assigns.room_code
    player_id = socket.assigns.player_id

    case GameServer.get_state(room_code) do
      %{} = state ->
        drawer = current_drawer(state)

        push(socket, "game_state", %{
          phase: state.phase,
          players: player_summary(state),
          round: state.round,
          max_rounds: state.max_rounds,
          time_left: state.time_left,
          current_drawer: drawer
        })

        # If reconnecting player is the current drawer, resend their context
        if player_id == drawer do
          case state.phase do
            :drawing ->
              push(socket, "drawer_word", %{word: state.current_word})

            :word_select ->
              push(socket, "word_select", %{
                drawer: drawer,
                choices: state.word_choices,
                round: state.round
              })

            _ ->
              :ok
          end
        end

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # Catch-all for unknown PubSub messages (avoid crashes)
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Terminate ───────────────────────────────────────────────────────────

  @doc "Schedule player removal after grace period when they disconnect."
  @impl true
  def terminate(_reason, socket) do
    room_code = socket.assigns[:room_code]
    player_id = socket.assigns[:player_id]

    if room_code && player_id do
      GameServer.schedule_remove_player(room_code, player_id)
    end

    :ok
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp check_room_exists(room_code) do
    query = from g in Game,
            where: g.room_code == ^room_code,
            select: count(g.id) > 0
    Repo.one(query)
  end

  defp player_summary(state) do
    Enum.map(state.player_order, fn pid ->
      p = Map.get(state.players, pid, %{username: "Unknown", score: 0, guessed: false, connected: false})
      %{player_id: pid, username: p.username, score: p.score, guessed: p.guessed, connected: p.connected}
    end)
  end

  defp current_drawer(%{player_order: order, current_drawer_index: idx}) do
    Enum.at(order, idx)
  end
end
