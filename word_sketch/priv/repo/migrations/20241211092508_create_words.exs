defmodule WordSketch.Repo.Migrations.CreateWords do
  use Ecto.Migration

  def change do
    create table(:words) do
      add :word, :string, null: false
    end
  end

end
