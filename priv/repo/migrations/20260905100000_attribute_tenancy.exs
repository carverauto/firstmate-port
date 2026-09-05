defmodule FirstmatePort.Repo.Migrations.AttributeTenancy do
  use Ecto.Migration

  @tenant_tables ~w(
    diagrams progress_items rolls no_mistakes_runs github_items event_logs
    diagrams_versions progress_items_versions rolls_versions
    no_mistakes_runs_versions github_items_versions
  )

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS t_local")

    for table <- @tenant_tables do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_schema = 't_local' AND table_name = '#{table}'
        ) THEN
          EXECUTE 'ALTER TABLE t_local.#{table} SET SCHEMA public';
        END IF;
      END $$;
      """)
    end

    execute("DROP SCHEMA IF EXISTS t_local")

    for table <- @tenant_tables do
      execute(
        "ALTER TABLE IF EXISTS #{table} ADD COLUMN IF NOT EXISTS tenant_slug text NOT NULL DEFAULT 'local'"
      )
    end

    drop_if_exists index(:progress_items, [:url], name: :progress_items_unique_url_index)

    create unique_index(:progress_items, [:tenant_slug, :url],
             where: "url <> ''",
             name: :progress_items_unique_tenant_url_index
           )

    drop_if_exists index(:github_items, [:html_url])
    create unique_index(:github_items, [:tenant_slug, :html_url])

    drop_if_exists index(:no_mistakes_runs, [:run_id])
    create unique_index(:no_mistakes_runs, [:tenant_slug, :run_id])

    alter table(:tenants) do
      remove_if_exists :nats_account, :text
      remove_if_exists :nats_user, :text
      remove_if_exists :nats_password, :text
    end
  end

  def down do
    alter table(:tenants) do
      add :nats_account, :text, default: "LOCAL", null: false
      add :nats_user, :text, default: "local", null: false
      add :nats_password, :text, default: "local", null: false
    end

    drop_if_exists index(:no_mistakes_runs, [:tenant_slug, :run_id])
    create unique_index(:no_mistakes_runs, [:run_id])
    drop_if_exists index(:github_items, [:tenant_slug, :html_url])
    create unique_index(:github_items, [:html_url])

    drop_if_exists index(:progress_items, [:tenant_slug, :url],
                     name: :progress_items_unique_tenant_url_index
                   )

    create unique_index(:progress_items, [:url],
             where: "url <> ''",
             name: :progress_items_unique_url_index
           )

    for table <- @tenant_tables do
      execute("ALTER TABLE IF EXISTS #{table} DROP COLUMN IF EXISTS tenant_slug")
    end
  end
end
