defmodule WordSketch.Repo.Migrations.CreateGames do
  use Ecto.Migration

  def change do
    create table(:games) do
      add :room_code, :string, unique: true
      add :creator_name, :string, unique: true
      add :creator_id, references(:users, on_delete: :nothing)
      add :word_id, references(:words, on_delete: :nothing)
      add :status, :string, default: "active"

      timestamps()
    end

    create index(:games, [:room_code])
    create index(:games, [:creator_name])

    # Modify the table to remove NOT NULL constraints
    drop constraint(:games, "games_creator_id_fkey")
    drop constraint(:games, "games_word_id_fkey")

    alter table(:games) do
      modify :creator_id, references(:users, on_delete: :nothing), null: true
      modify :word_id, references(:words, on_delete: :nothing), null: true
      modify :room_code, :string, null: true
    end

    # Drop old index and create new unique index for room_code
    # execute("DROP INDEX IF EXISTS games_room_code_index")
    # create unique_index(:games, [:room_code])
  end
end
