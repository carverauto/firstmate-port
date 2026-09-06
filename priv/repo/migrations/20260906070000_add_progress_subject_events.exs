defmodule FirstmatePort.Repo.Migrations.AddProgressSubjectEvents do
  use Ecto.Migration

  def change do
    alter table(:progress_events) do
      add :title, :text
      add :kind, :text
    end
  end
end
