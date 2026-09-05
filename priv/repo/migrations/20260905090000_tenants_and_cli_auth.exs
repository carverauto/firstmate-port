defmodule FirstmatePort.Repo.Migrations.TenantsAndCliAuth do
  use Ecto.Migration

  @tenant_tables ~w(
    diagrams progress_items rolls no_mistakes_runs github_items event_logs
    diagrams_versions progress_items_versions rolls_versions
    no_mistakes_runs_versions github_items_versions
  )

  def up do
    create table(:tenants, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :slug, :text, null: false
      add :name, :text, null: false
      add :nats_account, :text, null: false
      add :nats_user, :text, null: false
      add :nats_password, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:slug])

    execute("""
    INSERT INTO tenants (slug, name, nats_account, nats_user, nats_password, inserted_at, updated_at)
    VALUES ('local', 'Local', 'LOCAL', 'local', 'local', now(), now())
    """)

    alter table(:users) do
      add :tenant_slug, :text, null: false, default: "local"
    end

    create table(:device_codes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :device_code, :text, null: false
      add :user_code, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :user_id, :uuid
      add :tenant_slug, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :interval, :integer, null: false, default: 5
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_codes, [:device_code])
    create unique_index(:device_codes, [:user_code])

    execute("CREATE SCHEMA IF NOT EXISTS t_local")

    for table <- @tenant_tables do
      execute("ALTER TABLE IF EXISTS #{table} SET SCHEMA t_local")
    end
  end

  def down do
    for table <- @tenant_tables do
      execute("ALTER TABLE IF EXISTS t_local.#{table} SET SCHEMA public")
    end

    execute("DROP SCHEMA IF EXISTS t_local")
    drop_if_exists table(:device_codes)

    alter table(:users) do
      remove :tenant_slug
    end

    drop_if_exists table(:tenants)
  end
end
