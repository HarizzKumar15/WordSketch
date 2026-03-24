defmodule WordSketch.Repo.Migrations.CreatePlayerRounds do
  use Ecto.Migration

  def change do
    create table(:player_rounds) do
      add :round_id, references(:rounds, on_delete: :nothing), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :score, :integer, default: 0
      timestamps()
    end

    create index(:player_rounds, [:round_id])
    create index(:player_rounds, [:user_id])
  end


end
