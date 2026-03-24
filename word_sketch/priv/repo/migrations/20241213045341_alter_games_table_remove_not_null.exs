defmodule WordSketch.Repo.Migrations.AlterGamesTableRemoveNotNull do
  use Ecto.Migration

  def change do
    drop constraint(:games, "games_creator_id_fkey")
    drop constraint(:games, "games_word_id_fkey")
    alter table(:games) do
      modify :creator_id, references(:users, on_delete: :nothing), null: true
      modify :word_id, references(:words, on_delete: :nothing), null: true
      modify :room_code, :string, null: true
    end
    execute("DROP INDEX IF EXISTS games_room_code_index")
    create unique_index(:games, [:room_code])
  end
end
