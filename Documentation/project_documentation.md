# WordSketch Project Documentation

## Overview

WordSketch is a real-time multiplayer drawing and guessing game built with Elixir and the Phoenix web framework. The game is highly interactive and resembles popular titles like Pictionary or Skribbl.io. 

It uses **Phoenix Channels** for real-time WebSockets and **Elixir's OTP** for handling authoritative state management per game room.

## Architecture

The system is designed with low-latency and concurrent design principles in mind:

- **GameServer (`WordSketch.GameServer`)**: An authoritative game state manager implemented as a `GenServer`. One process is spawned per room. All core game logic (turn advancement, timer countdown, scoring, validating guesses) is executed here. 
- **RoomChannel (`WordSketchWeb.RoomChannel`)**: The WebSocket transport layer. This module handles real-time communication. For drawing events (`draw`, `draw_batch`, `clear_canvas`), the channel broadcasts directly to clients to ensure the lowest latency possible. For state mutations, it delegates to the associated `GameServer`.
- **Registry & Dynamic Supervisor**: Each `GameServer` is dynamically started by an OTP `DynamicSupervisor`. Rooms are registered in a local `Registry` module, enabling fast O(1) lookups by room code and ensuring state is cleaned up when processes exit.

## Game Loop

1. **Lobby (`:lobby`)**: Players join the room using a unique room code. Requires at least 2 players to start a game.
2. **Word Selection (`:word_select`)**: The designated drawer is presented with three random words to pick from.
3. **Drawing Phase (`:drawing`)**: A 60-second timer begins ticking. The `GameServer` broadcasts `timer_tick` events every second. The drawer draws on a canvas, while other players submit guesses.
4. **Scoring**: Points are dynamically calculated based on elapsed time:
   - **Guessers**: Receive `max(100, 500 - elapsed_time * 7)` points.
   - **Drawer**: Receives a flat 100 points per correct guess.
5. **Turn End (`:turn_end`)**: Once the timer runs out or all guessers guess the word correctly, the round advances, and the next player becomes the drawer.
6. **Game Over (`:game_over`)**: Once 3 rounds (by default) conclude, the leaderboard is displayed based on total accumulated score.

## How to Run

1. **Prerequisites**: Ensure you have Elixir, Erlang, and PostgreSQL installed.

2. **Setup Dependencies & Database**:
   Navigate to the project root directory in the terminal, and run:
   ```bash
   mix setup
   ```
   This command installs all required Elixir and JS/CSS dependencies, creates the database (`ecto.setup`), and builds the static assets.

3. **Start the Phoenix Server**:
   ```bash
   mix phx.server
   ```
   To start the server with an interactive Elixir shell (useful for interacting with `GameServer` running instances or debugging), run:
   ```bash
   iex -S mix phx.server
   ```

4. **Access the Application**:
   Open a browser and navigate to [http://localhost:4000](http://localhost:4000) to start playing.
