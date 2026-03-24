defmodule WordSketch.Repo.Migrations.CreateRounds do
  use Ecto.Migration

  def change do
    create table(:rounds) do
      add :game_id, references(:games, on_delete: :nothing), null: false
      add :round_number, :integer, null: false
      add :word, :string, null: false
      timestamps()
    end

    create index(:rounds, [:game_id])
  end


end
