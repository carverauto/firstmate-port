defmodule FirstmatePort.Repo.Migrations.AddProgressEvents do
  use Ecto.Migration

  def change do
    alter table(:progress_items) do
      add(:status, :text, default: "")
      add(:assignee, :text, default: "")
      add(:extra_workers, {:array, :text}, default: [])
      add(:interruption, :text, default: "")
    end

    create(unique_index(:progress_items, [:id, :tenant_slug]))

    create table(:progress_events) do
      add(:tenant_slug, :text, null: false)

      add(:item_id, references(:progress_items, type: :text, with: [tenant_slug: :tenant_slug]),
        null: false
      )

      add(:kind, :text)
      add(:title, :text)
      add(:status, :text)
      add(:assignee, :text)
      add(:extra_workers, {:array, :text})
      add(:interruption, :text)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:progress_events, [:tenant_slug, :item_id, :id]))
  end
end
