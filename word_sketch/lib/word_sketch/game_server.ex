defmodule WordSketch.GameServer do
  @moduledoc """
  Authoritative game state manager for a single room.

  One GameServer process is spawned per room via DynamicSupervisor + Registry.
  All game logic (turns, scoring, validation) lives here. The RoomChannel
  delegates to this module and only handles communication.

  ## Design decisions

  - **Registry-based naming**: Each process is registered as `{GameRegistry, room_code}`.
    This gives O(1) lookups and automatic cleanup on process exit.

  - **Timer via Process.send_after/3**: Each tick decrements `time_left` and
    broadcasts through PubSub. When time reaches 0 the turn ends automatically.
    The timer ref is stored so we can cancel it on early turn-end (all guessed).

  - **Scoring**: Guessers earn `max(100, 500 - elapsed * 7)`. The drawer earns
    100 per correct guess. This rewards fast guessers and incentivizes good drawings.

  - **Phase machine**: `:lobby → :word_select → :drawing → :turn_end → :word_select`
    (loops until `round > max_rounds`, then → `:game_over`).

  - **Concurrency safety**: All state mutation goes through GenServer calls/casts.
    No shared mutable state outside the process.
  """

  use GenServer
  require Logger

  alias WordSketch.WordBank

  # ── Configuration ──────────────────────────────────────────────────────

  @round_time 60
  @max_rounds 3
  @word_choices 3
  @min_players 2
  @tick_interval 1_000
  @disconnect_grace_ms 5_000
  @vowels ~w(a e i o u)

  # ── Public API ─────────────────────────────────────────────────────────

  @doc "Start a GameServer for the given room code under the DynamicSupervisor."
  @spec start(String.t()) :: {:ok, pid()} | {:error, term()}
  def start(room_code) do
    DynamicSupervisor.start_child(
      WordSketch.GameSupervisor,
      {__MODULE__, room_code}
    )
  end

  @doc "Start link (called by the supervisor)."
  def start_link(room_code) do
    GenServer.start_link(__MODULE__, room_code, name: via(room_code))
  end

  @doc "Returns the game state (for debugging / Presence metadata)."
  @spec get_state(String.t()) :: map() | nil
  def get_state(room_code) do
    call_if_alive(room_code, :get_state)
  end

  @doc "Add a player to the room. Reconnects if player_id already exists."
  @spec add_player(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_player(room_code, player_id, username) do
    call_if_alive(room_code, {:add_player, player_id, username})
  end

  @doc "Schedule a player for removal after the grace period."
  @spec schedule_remove_player(String.t(), String.t()) :: :ok
  def schedule_remove_player(room_code, player_id) do
    call_if_alive(room_code, {:schedule_remove_player, player_id})
  end

  @doc "Transition from :lobby to :word_select. Requires >= min_players."
  @spec start_game(String.t(), integer()) :: :ok | {:error, term()}
  def start_game(room_code, rounds \\ 3) do
    call_if_alive(room_code, {:start_game, rounds})
  end

  @doc "Transition from :game_over back to :lobby."
  @spec return_to_lobby(String.t()) :: :ok | {:error, term()}
  def return_to_lobby(room_code) do
    call_if_alive(room_code, :return_to_lobby)
  end

  @doc "Drawer selects a word from the offered choices."
  @spec select_word(String.t(), String.t()) :: :ok | {:error, term()}
  def select_word(room_code, word) do
    call_if_alive(room_code, {:select_word, word})
  end

  @doc "A player submits a guess. Returns the result atom."
  @spec submit_guess(String.t(), String.t(), String.t()) ::
          {:correct, integer()} | :wrong | :already_guessed | :is_drawer | {:error, term()}
  def submit_guess(room_code, user_id, guess) do
    call_if_alive(room_code, {:submit_guess, user_id, guess})
  end

  @doc """
  Ensure a GameServer exists for the room. Creates one if not running.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(room_code) do
    case Registry.lookup(WordSketch.GameRegistry, room_code) do
      [{pid, _}] -> {:ok, pid}
      [] -> start(room_code)
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(room_code) do
    Logger.info("GameServer started for room #{room_code}")

    state = %{
      room_code: room_code,
      phase: :lobby,
      players: %{},
      player_order: [],
      current_drawer_index: 0,
      current_word: nil,
      word_choices: [],
      round: 1,
      max_rounds: @max_rounds,
      time_left: @round_time,
      guessed_players: [],
      timer_ref: nil,
      disconnect_timers: %{},
      revealed_indices: MapSet.new(),
      reveal_schedule: []
    }

    {:ok, state}
  end

  # ── get_state ──────────────────────────────────────────────────────────

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # ── add_player ─────────────────────────────────────────────────────────

  def handle_call({:add_player, player_id, username}, _from, state) do
    if Map.has_key?(state.players, player_id) do
      # ── Reconnect path ─────────────────────────────────────────────────
      # Cancel any pending disconnect timer
      {new_timers, _} = cancel_disconnect_timer(state.disconnect_timers, player_id)

      # Mark as connected, update username in case it changed
      players = Map.update!(state.players, player_id, fn p ->
        %{p | connected: true, username: username}
      end)

      new_state = %{state | players: players, disconnect_timers: new_timers}

      Logger.info("Player #{player_id} (#{username}) reconnected to room #{state.room_code}")

      broadcast(state.room_code, "player_joined", %{
        player_id: player_id,
        username: username,
        players: player_summary(new_state)
      })

      {:reply, :ok, new_state}
    else
      # ── New player path ─────────────────────────────────────────────────
      players = Map.put(state.players, player_id, %{
        username: username,
        score: 0,
        guessed: false,
        connected: true
      })
      player_order = state.player_order ++ [player_id]
      new_state = %{state | players: players, player_order: player_order}

      broadcast(state.room_code, "player_joined", %{
        player_id: player_id,
        username: username,
        players: player_summary(new_state)
      })

      {:reply, :ok, new_state}
    end
  end

  # ── schedule_remove_player ──────────────────────────────────────────────

  def handle_call({:schedule_remove_player, player_id}, _from, state) do
    if not Map.has_key?(state.players, player_id) do
      {:reply, :ok, state}
    else
      # Cancel any existing disconnect timer for this player (rapid disconnect safety)
      {timers, _} = cancel_disconnect_timer(state.disconnect_timers, player_id)

      # Mark player as disconnected
      players = Map.update!(state.players, player_id, fn p ->
        %{p | connected: false}
      end)

      # Schedule actual removal after grace period
      timer_ref = Process.send_after(self(), {:execute_remove_player, player_id}, @disconnect_grace_ms)
      timers = Map.put(timers, player_id, timer_ref)

      new_state = %{state | players: players, disconnect_timers: timers}

      Logger.info("Player #{player_id} disconnected from room #{state.room_code}, grace period started")

      {:reply, :ok, new_state}
    end
  end

  # ── start_game ─────────────────────────────────────────────────────────

  def handle_call({:start_game, rounds}, _from, %{phase: :lobby} = state) do
    connected_count = count_connected(state)

    if connected_count < @min_players do
      {:reply, {:error, :not_enough_players}, state}
    else
      # Reset scores and guessed status for all players for the new game
      players_reset = Map.new(state.players, fn {uid, p} -> 
        {uid, %{p | score: 0, guessed: false}} 
      end)

      # Find the first connected player to be the initial drawer
      first_drawer_index =
        Enum.find_index(state.player_order, fn pid ->
          case Map.get(players_reset, pid) do
            %{connected: true} -> true
            _ -> false
          end
        end) || 0

      new_state = %{state | max_rounds: rounds, players: players_reset, round: 1, current_drawer_index: first_drawer_index}
      new_state = start_word_select(new_state)

      broadcast(state.room_code, "game_started", %{
        players: player_summary(new_state),
        max_rounds: rounds
      })

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:start_game, _rounds}, _from, state) do
    {:reply, {:error, :game_already_started}, state}
  end

  # ── return_to_lobby ────────────────────────────────────────────────────

  def handle_call(:return_to_lobby, _from, %{phase: :game_over} = state) do
    # Reset scores and guessed status for all players
    players_reset = Map.new(state.players, fn {uid, p} -> 
      {uid, %{p | score: 0, guessed: false}} 
    end)

    new_state = %{state | phase: :lobby, players: players_reset, current_word: nil, word_choices: [], round: 1, guessed_players: [], revealed_indices: MapSet.new()}

    broadcast(state.room_code, "returned_to_lobby", %{
      players: player_summary(new_state)
    })

    {:reply, :ok, new_state}
  end

  def handle_call(:return_to_lobby, _from, state) do
    {:reply, {:error, :not_in_game_over}, state}
  end

  # ── select_word ────────────────────────────────────────────────────────

  def handle_call({:select_word, word}, _from, %{phase: :word_select} = state) do
    if word in state.word_choices do
      new_state = %{state |
        current_word: word,
        phase: :drawing,
        time_left: @round_time,
        guessed_players: [],
        revealed_indices: MapSet.new(),
        reveal_schedule: reveal_schedule_for_word(word)
      }

      # Reset guessed flag for all players
      players = Map.new(new_state.players, fn {uid, p} -> {uid, %{p | guessed: false}} end)
      new_state = %{new_state | players: players}

      # Start the countdown timer
      new_state = schedule_tick(new_state)

      drawer = current_drawer(new_state)
      word_hint = get_masked_word(word, MapSet.new())

      broadcast(state.room_code, "turn_started", %{
        drawer: drawer,
        word_hint: word_hint,
        round: new_state.round,
        time_left: new_state.time_left
      })

      # Send the actual word only to the drawer (via targeted PubSub topic)
      broadcast(state.room_code, "drawer_word", %{word: word, drawer: drawer})

      {:reply, :ok, new_state}
    else
      {:reply, {:error, :invalid_word_choice}, state}
    end
  end

  def handle_call({:select_word, _word}, _from, state) do
    {:reply, {:error, :not_in_word_select_phase}, state}
  end

  # ── submit_guess ───────────────────────────────────────────────────────

  def handle_call({:submit_guess, player_id, guess}, _from, %{phase: :drawing} = state) do
    drawer = current_drawer(state)
    player = Map.get(state.players, player_id)

    cond do
      player == nil ->
        {:reply, {:error, :not_in_game}, state}

      not player.connected ->
        {:reply, {:error, :player_disconnected}, state}

      player_id == drawer ->
        {:reply, :is_drawer, state}

      player_id in state.guessed_players ->
        {:reply, :already_guessed, state}

      normalize(guess) == normalize(state.current_word) ->
        # Correct guess
        elapsed = @round_time - state.time_left
        guesser_points = guesser_score(elapsed)
        drawer_points = 100

        # Update guesser
        players = Map.update!(state.players, player_id, fn p ->
          %{p | score: p.score + guesser_points, guessed: true}
        end)

        # Update drawer
        players = Map.update!(players, drawer, fn p ->
          %{p | score: p.score + drawer_points}
        end)

        guessed_players = [player_id | state.guessed_players]

        new_state = %{state | players: players, guessed_players: guessed_players}

        broadcast(state.room_code, "correct_guess", %{
          player_id: player_id,
          username: player.username,
          points: guesser_points,
          players: player_summary(new_state)
        })

        # Check if all non-drawer players have guessed
        new_state = maybe_all_guessed(new_state)

        {:reply, {:correct, guesser_points}, new_state}

      true ->
        # Wrong guess — broadcast it as a chat message
        broadcast(state.room_code, "chat_message", %{
          player_id: player_id,
          username: player.username,
          message: guess
        })

        {:reply, :wrong, state}
    end
  end

  def handle_call({:submit_guess, _user_id, _guess}, _from, state) do
    {:reply, {:error, :not_in_drawing_phase}, state}
  end

  # ── Timer tick ─────────────────────────────────────────────────────────

  @impl true
  def handle_info(:tick, %{phase: :drawing} = state) do
    new_time = state.time_left - 1

    if new_time <= 0 do
      # Time's up — end the turn
      new_state = %{state | time_left: 0, timer_ref: nil}
      new_state = end_turn(new_state)
      {:noreply, new_state}
    else
      new_state = %{state | time_left: new_time}

      # Check if this tick matches the dynamic reveal schedule
      new_state =
        if new_time in new_state.reveal_schedule do
          maybe_reveal_letter(new_state)
        else
          new_state
        end

      broadcast(state.room_code, "timer_tick", %{time_left: new_time})

      new_state = schedule_tick(new_state)
      {:noreply, new_state}
    end
  end

  # Stale tick from a cancelled timer (ignore)
  def handle_info(:tick, state) do
    {:noreply, state}
  end

  # Auto-advance from :turn_end after a brief delay
  def handle_info(:advance_turn, %{phase: :turn_end} = state) do
    new_state = advance_to_next_turn(state)
    {:noreply, new_state}
  end

  def handle_info(:advance_turn, state) do
    {:noreply, state}
  end

  # ── Disconnect grace period expiry ─────────────────────────────────────

  def handle_info({:execute_remove_player, player_id}, state) do
    stored_ref = Map.get(state.disconnect_timers, player_id)

    # If no timer ref exists, the player already reconnected — ignore
    if stored_ref == nil do
      {:noreply, state}
    else
      # Check if player is still disconnected (guard against race condition)
      player = Map.get(state.players, player_id)

      if player == nil or player.connected do
        # Player reconnected between timer scheduling and firing — clean up timer entry
        timers = Map.delete(state.disconnect_timers, player_id)
        {:noreply, %{state | disconnect_timers: timers}}
      else
        # Grace period expired and player is still gone — actually remove them
        Logger.info("Grace period expired for #{player_id} in room #{state.room_code}, removing")
        do_remove_player(player_id, state)
      end
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────

  # Registry name tuple
  defp via(room_code) do
    {:via, Registry, {WordSketch.GameRegistry, room_code}}
  end

  # Safe call that returns {:error, :game_not_found} if process is gone
  defp call_if_alive(room_code, message) do
    case Registry.lookup(WordSketch.GameRegistry, room_code) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, message)
        catch
          :exit, _ -> {:error, :game_not_found}
        end

      [] ->
        {:error, :game_not_found}
    end
  end

  # ── Phase transitions ──────────────────────────────────────────────────

  defp start_word_select(state) do
    drawer_id = Enum.at(state.player_order, state.current_drawer_index)
    drawer_player = Map.get(state.players, drawer_id)

    # Safety: if the selected drawer is disconnected, skip to next turn
    if drawer_player == nil or not drawer_player.connected do
      Logger.warning("Drawer #{inspect(drawer_id)} is not connected, skipping turn")
      case find_next_connected_drawer(state) do
        {:ok, next_index, next_round} ->
          if next_round > state.max_rounds do
            end_game(state)
          else
            new_state = %{state | current_drawer_index: next_index, round: next_round}
            start_word_select(new_state)
          end

        :not_enough_players ->
          end_game(state)
      end
    else
      words = WordBank.get_random_words(@word_choices)

      new_state = %{state |
        phase: :word_select,
        word_choices: words,
        current_word: nil,
        guessed_players: [],
        time_left: @round_time
      }

      broadcast(state.room_code, "word_select", %{
        drawer: drawer_id,
        choices: words,
        round: new_state.round
      })

      new_state
    end
  end

  defp end_turn(state) do
    state = cancel_timer(state)

    broadcast(state.room_code, "turn_ended", %{
      word: state.current_word,
      players: player_summary(state),
      round: state.round
    })

    new_state = %{state | phase: :turn_end}

    # Auto-advance after 5 seconds
    Process.send_after(self(), :advance_turn, 5_000)

    new_state
  end

  defp advance_to_next_turn(state) do
    case find_next_connected_drawer(state) do
      {:ok, next_index, next_round} ->
        if next_round > state.max_rounds do
          end_game(state)
        else
          new_state = %{state | round: next_round, current_drawer_index: next_index}
          start_word_select(new_state)
        end

      :not_enough_players ->
        end_game(state)
    end
  end

  # Ring-search: starting from current_drawer_index + 1, walk through player_order
  # wrapping around. When we wrap past the end, bump the round. Return the first
  # index whose player is connected, or :not_enough_players.
  defp find_next_connected_drawer(state) do
    total = length(state.player_order)

    if total == 0 do
      :not_enough_players
    else
      start_idx = state.current_drawer_index

      result =
        Enum.reduce_while(1..total, :not_enough_players, fn step, _acc ->
          check_idx = rem(start_idx + step, total)
          wrapped? = (start_idx + step) >= total

          pid = Enum.at(state.player_order, check_idx)
          player = Map.get(state.players, pid)

          if player != nil and player.connected do
            next_round = if wrapped?, do: state.round + 1, else: state.round
            {:halt, {:ok, check_idx, next_round}}
          else
            {:cont, :not_enough_players}
          end
        end)

      result
    end
  end

  defp end_game(state) do
    state = cancel_timer(state)

    # Cancel all pending disconnect timers to prevent stale removals
    Enum.each(state.disconnect_timers, fn {_pid, ref} ->
      Process.cancel_timer(ref)
    end)

    # Build final leaderboard sorted by score descending
    leaderboard =
      state.players
      |> Enum.sort_by(fn {_pid, p} -> p.score end, :desc)
      |> Enum.map(fn {pid, p} -> %{player_id: pid, username: p.username, score: p.score} end)

    broadcast(state.room_code, "game_over", %{leaderboard: leaderboard})

    %{state | phase: :game_over, timer_ref: nil, disconnect_timers: %{}}
  end

  # Check if every connected non-drawer player has guessed correctly
  defp maybe_all_guessed(%{phase: :drawing} = state) do
    drawer = current_drawer(state)

    # Only count connected, non-drawer players
    connected_non_drawer_ids =
      state.player_order
      |> Enum.reject(&(&1 == drawer))
      |> Enum.filter(fn pid ->
        case Map.get(state.players, pid) do
          %{connected: true} -> true
          _ -> false
        end
      end)

    all_guessed = Enum.all?(connected_non_drawer_ids, fn pid -> pid in state.guessed_players end)

    if all_guessed and length(connected_non_drawer_ids) > 0 do
      end_turn(state)
    else
      state
    end
  end

  defp maybe_all_guessed(state), do: state

  # ── Scoring ────────────────────────────────────────────────────────────

  defp guesser_score(elapsed_seconds) do
    max(100, 500 - elapsed_seconds * 7)
  end

  # ── Timer management ───────────────────────────────────────────────────

  defp schedule_tick(state) do
    ref = Process.send_after(self(), :tick, @tick_interval)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  # ── Utilities ──────────────────────────────────────────────────────────

  defp current_drawer(%{player_order: order, current_drawer_index: idx}) do
    Enum.at(order, idx)
  end

  defp normalize(str) when is_binary(str) do
    str |> String.trim() |> String.downcase()
  end

  # ── Word reveal helpers ────────────────────────────────────────────────

  # Generate the masked word with revealed letters shown.
  # Example: get_masked_word("guitar", MapSet.new([0, 2])) => "g _ i _ _ _"
  defp get_masked_word(word, revealed_indices) do
    word
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn
      {" ", _idx} -> " "
      {char, idx} -> if idx in revealed_indices, do: char, else: "_"
    end)
    |> Enum.join(" ")
  end

  # Compute a dynamic reveal schedule based on word length.
  # Short words (≤5 chars) get fewer, earlier reveals. Longer words get 3 reveals.
  defp reveal_schedule_for_word(word) do
    alpha_len = word |> String.graphemes() |> Enum.count(&(&1 != " "))

    if alpha_len <= 5 do
      [50, 30]
    else
      [45, 30, 15]
    end
  end

  # Attempt to reveal one letter. Only runs during :drawing phase.
  # Respects max reveal cap (~35%) and short-word guard (≤3 chars → max 1).
  defp maybe_reveal_letter(%{phase: :drawing, current_word: word} = state) when word != nil do
    graphemes = String.graphemes(word)

    alpha_count = Enum.count(graphemes, &(&1 != " "))
    max_reveals = if alpha_count <= 3, do: 1, else: max(1, trunc(alpha_count * 0.35))

    if MapSet.size(state.revealed_indices) >= max_reveals do
      state
    else
      case select_next_reveal_index(graphemes, state.revealed_indices) do
        nil ->
          state

        chosen_idx ->
          letter = Enum.at(graphemes, chosen_idx)
          new_revealed = MapSet.put(state.revealed_indices, chosen_idx)
          new_state = %{state | revealed_indices: new_revealed}

          masked = get_masked_word(word, new_revealed)

          broadcast(state.room_code, "word_update", %{word_hint: masked})
          broadcast(state.room_code, "hint_revealed", %{index: chosen_idx, letter: letter})

          new_state
      end
    end
  end

  defp maybe_reveal_letter(state), do: state

  # Smart letter selection:
  # 1. Build candidate indices (non-space, not already revealed)
  # 2. Filter out indices adjacent to already-revealed ones
  # 3. From remaining, prefer consonants over vowels
  # 4. Fall back to adjacent if no non-adjacent options exist
  # 5. Final fallback to vowels if only vowels remain
  defp select_next_reveal_index(graphemes, revealed) do
    # All unrevealed, non-space indices
    candidates =
      graphemes
      |> Enum.with_index()
      |> Enum.filter(fn {ch, idx} -> ch != " " and idx not in revealed end)
      |> Enum.map(fn {ch, idx} -> {idx, ch} end)

    case candidates do
      [] ->
        nil

      _ ->
        # Partition into non-adjacent and adjacent
        {non_adjacent, adjacent} =
          Enum.split_with(candidates, fn {idx, _ch} ->
            not MapSet.member?(revealed, idx - 1) and
            not MapSet.member?(revealed, idx + 1)
          end)

        # Prefer non-adjacent; fall back to adjacent
        pool = if non_adjacent != [], do: non_adjacent, else: adjacent

        # Within the pool, prefer consonants
        {consonants, vowels} =
          Enum.split_with(pool, fn {_idx, ch} ->
            String.downcase(ch) not in @vowels
          end)

        chosen_pool = if consonants != [], do: consonants, else: vowels

        {idx, _ch} = Enum.random(chosen_pool)
        idx
    end
  end

  defp clamp_drawer_index(%{player_order: []}), do: 0

  defp clamp_drawer_index(%{player_order: order, current_drawer_index: idx}) do
    min(idx, length(order) - 1)
  end

  defp player_summary(state) do
    Enum.map(state.player_order, fn pid ->
      p = Map.get(state.players, pid, %{username: "Unknown", score: 0, guessed: false, connected: false})
      %{player_id: pid, username: p.username, score: p.score, guessed: p.guessed, connected: p.connected}
    end)
  end

  defp count_connected(state) do
    state.players
    |> Enum.count(fn {_pid, p} -> p.connected end)
  end

  # Cancel a disconnect timer for a player. Returns {updated_timers, cancelled_ref_or_nil}
  defp cancel_disconnect_timer(timers, player_id) do
    case Map.pop(timers, player_id) do
      {nil, timers} -> {timers, nil}
      {ref, timers} ->
        Process.cancel_timer(ref)
        {timers, ref}
    end
  end

  # Actual player removal logic (used by execute_remove_player)
  defp do_remove_player(player_id, state) do
    leaving_player = Map.get(state.players, player_id)
    leaving_username = if leaving_player, do: leaving_player.username, else: player_id

    # Remember who the current drawer IS before we mutate player_order
    current_drawer_id = current_drawer(state)

    players = Map.delete(state.players, player_id)
    player_order = List.delete(state.player_order, player_id)
    guessed_players = List.delete(state.guessed_players, player_id)
    timers = Map.delete(state.disconnect_timers, player_id)

    new_state = %{state |
      players: players,
      player_order: player_order,
      guessed_players: guessed_players,
      disconnect_timers: timers
    }

    broadcast(state.room_code, "player_left", %{
      player_id: player_id,
      username: leaving_username,
      players: player_summary(new_state)
    })

    cond do
      # If no players left, shut down
      map_size(players) == 0 ->
        {:stop, :normal, new_state}

      # If we are mid-game and fewer than min connected players remain, end the game
      state.phase in [:word_select, :drawing, :turn_end] and count_connected(new_state) < @min_players ->
        new_state = end_game(new_state)
        {:noreply, new_state}

      # If the current drawer was the one removed mid-turn, advance to next turn
      state.phase in [:word_select, :drawing] and current_drawer_id == player_id ->
        # Recalculate the drawer index based on the stable current_drawer_id position
        # After removal the next player in sequence occupies the old index, so we
        # set current_drawer_index to the position just before it so advance_to_next_turn
        # will find the correct next connected drawer.
        adjusted_index = max(0, Enum.find_index(player_order, &(&1 == current_drawer_id)) || 0)
        new_state = %{new_state | current_drawer_index: max(0, adjusted_index - 1)}
        new_state = cancel_timer(new_state)
        new_state = advance_to_next_turn(new_state)
        {:noreply, new_state}

      true ->
        # A non-drawer was removed. Recalculate drawer index to keep it pointing
        # at the same player. After array shift, look up the current drawer's new position.
        new_index =
          case Enum.find_index(player_order, &(&1 == current_drawer_id)) do
            nil -> clamp_drawer_index(new_state)
            idx -> idx
          end

        new_state = %{new_state | current_drawer_index: new_index}
        new_state = maybe_all_guessed(new_state)
        {:noreply, new_state}
    end
  end

  defp broadcast(room_code, event, payload) do
    Phoenix.PubSub.broadcast(WordSketch.PubSub, "game:" <> room_code, {event, payload})
  end
end
