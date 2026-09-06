defmodule FirstmatePort.Repo.Migrations.BuildTracking do
  use Ecto.Migration

  def up do
    create table(:docker_builds, primary_key: false) do
      add :id, :text, primary_key: true
      add :repository, :text, null: false
      add :tag, :text, null: false
      add :status, :text, null: false
      add :digest, :text, default: ""
      add :dockerfile, :text, default: ""
      add :context, :text, default: ""
      add :pr_url, :text, default: ""
      add :issue_url, :text, default: ""
      add :outcome, :text, default: ""
      add :tenant_slug, :text, null: false, default: "local"
      timestamps(type: :utc_datetime_usec)
    end

    create table(:buildbuddy_invocations, primary_key: false) do
      add :id, :text, primary_key: true
      add :invocation_id, :text, null: false
      add :host, :text, default: ""
      add :status, :text, default: ""
      add :commit_sha, :text, default: ""
      add :branch, :text, default: ""
      add :repo_url, :text, default: ""
      add :buildbuddy_url, :text, default: ""
      add :pr_url, :text, default: ""
      add :outcome, :text, default: ""
      add :tenant_slug, :text, null: false, default: "local"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:buildbuddy_invocations, [:tenant_slug, :invocation_id])

    for table <- ~w(docker_builds buildbuddy_invocations) do
      create table(String.to_atom(table <> "_versions"), primary_key: false) do
        add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
        add :version_action_type, :text, null: false
        add :version_action_name, :text, null: false
        add :changes, :map, default: %{}
        add :version_source_id, :text
        add :user_id, :uuid
        add :tenant_slug, :text, null: false, default: "local"

        add :version_inserted_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :version_updated_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end
    end
  end

  def down do
    for table <- ~w(
      buildbuddy_invocations_versions docker_builds_versions
      buildbuddy_invocations docker_builds
    ) do
      drop_if_exists table(String.to_atom(table))
    end
  end
end
