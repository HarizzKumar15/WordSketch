defmodule WordSketch.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string
      add :room_code, :string
      add :role, :string, default: "player"
      add :score, :integer, default: 0
      timestamps()
    end

    create index(:users, [:username, :room_code])
  end
end
