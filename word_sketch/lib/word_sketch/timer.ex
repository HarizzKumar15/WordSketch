defmodule WordSketch.GameTimer do
  use GenServer

  def start_link(initial_time, room_code) do
    GenServer.start_link(__MODULE__, %{time_left: initial_time, winner: nil, room_code: room_code}, name: via_tuple(room_code))
  end

  defp via_tuple(room_code) do
    {:via, Registry, {WordSketch.TimerRegistry, room_code}}
  end

  def guess_correct(room_code, user, guess_time) do
    GenServer.call(via_tuple(room_code), {:correct_guess, user, guess_time})
  end

  def get_time(room_code) do
    GenServer.call(via_tuple(room_code), :get_time)
  end

  # GenServer Callbacks
  def init(state) do
    # Ensure the first tick is sent immediately
    send(self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, %{time_left: 0, winner: winner, room_code: room_code} = state) do
    Phoenix.PubSub.broadcast(WordSketch.PubSub, "room:#{room_code}", %{event: :game_over, winner: winner})
    {:stop, :normal, state}
  end

  def handle_info(:tick, %{time_left: time_left, room_code: room_code} = state) do
    Phoenix.PubSub.broadcast(WordSketch.PubSub, "room:#{room_code}", %{event: :time_update, time_left: time_left})
    # Always schedule the next tick, regardless of any guesses
    Process.send_after(self(), :tick, 1000)
    {:noreply, %{state | time_left: time_left - 1}}
  end

  def handle_call(:get_time, _from, state) do
    {:reply, state.time_left, state}
  end

  def handle_call({:correct_guess, user, guess_time}, _from, state) do
    new_state =
      case state.winner do
        nil -> %{state | winner: %{user: user, time: guess_time}}
        _ -> state
      end

    # Broadcast correct guess event
    Phoenix.PubSub.broadcast(WordSketch.PubSub, "room:#{state.room_code}", %{event: :correct_guess, user: user, guess_time: guess_time})

    {:reply, :ok, new_state}
  end
end
