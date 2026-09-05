defmodule FirstmatePort.Repo.Migrations.CreateHubTables do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :email, :citext, null: false
      add :name, :text
      add :role, :text, null: false, default: "human"
      add :hashed_api_key, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:diagrams, primary_key: false) do
      add :id, :text, primary_key: true
      add :title, :text, null: false
      add :notes, :text, default: ""
      add :html, :binary, null: false
      add :png, :binary
      add :svg, :binary
      timestamps(type: :utc_datetime_usec)
    end

    create table(:progress_items, primary_key: false) do
      add :id, :text, primary_key: true
      add :kind, :text, null: false
      add :title, :text, null: false
      add :url, :text, default: ""
      add :body, :text, default: ""
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:progress_items, [:url],
             where: "url <> ''",
             name: :progress_items_unique_url_index
           )

    create table(:rolls, primary_key: false) do
      add :id, :text, primary_key: true
      add :cluster, :text, null: false
      add :namespace, :text, null: false
      add :status, :text, null: false
      add :image_tag, :text, null: false
      add :rebuilt, {:array, :text}, default: []
      add :copied, {:array, :text}, default: []
      add :helm_revision, :text, default: ""
      add :pr_url, :text, default: ""
      add :issue_url, :text, default: ""
      add :outcome, :text, default: ""
      timestamps(type: :utc_datetime_usec)
    end

    create table(:no_mistakes_runs, primary_key: false) do
      add :id, :text, primary_key: true
      add :run_id, :text, null: false
      add :branch, :text, null: false
      add :step, :text, default: ""
      add :findings, :text, default: ""
      add :pr_url, :text, default: ""
      add :outcome, :text, default: ""
      add :intent, :text, default: ""
      add :logs, :text, default: ""
      add :public_summary, :text, default: ""
      add :firewall_verdict, :text, default: "none"
      add :respond_action, :text, default: ""
      add :respond_findings, :text, default: ""
      add :respond_instructions, :text, default: ""
      add :respond_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:no_mistakes_runs, [:run_id])

    create table(:github_items, primary_key: false) do
      add :id, :text, primary_key: true
      add :kind, :text, null: false
      add :html_url, :text, null: false
      add :title, :text, null: false
      add :state, :text, null: false, default: "open"
      add :check_status, :text, default: "none"
      add :buildbuddy_url, :text, default: ""
      add :github_updated_at, :utc_datetime_usec
      add :assignment_task_id, :text
      add :assignment_worker, :text
      add :assignment_status, :text
      add :assignment_updated_at, :utc_datetime_usec
      add :firewall_verdict, :text, default: "none"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:github_items, [:html_url])

    create table(:job_ticks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :kind, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:event_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :record_id, :text, null: false
      add :version, :bigint, null: false, default: 1
      add :metadata, :map, default: %{}
      add :data, :map, default: %{}
      add :changed_attributes, :map, default: %{}
      add :user_id, :uuid
      add :resource, :text
      add :action, :text
      add :action_type, :text
      add :occurred_at, :utc_datetime_usec
    end

    create table(:users_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :version_action_type, :text, null: false
      add :version_action_name, :text, null: false
      add :changes, :map, default: %{}
      add :version_source_id, :uuid
      add :user_id, :uuid

      add :version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    for table <- ~w(diagrams progress_items rolls no_mistakes_runs github_items) do
      versions = table <> "_versions"

      create table(String.to_atom(versions), primary_key: false) do
        add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
        add :version_action_type, :text, null: false
        add :version_action_name, :text, null: false
        add :changes, :map, default: %{}
        add :version_source_id, :text
        add :user_id, :uuid

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
    for table <-
          ~w(github_items_versions no_mistakes_runs_versions rolls_versions progress_items_versions diagrams_versions users_versions event_logs job_ticks github_items no_mistakes_runs rolls progress_items diagrams users) do
      drop_if_exists table(String.to_atom(table))
    end
  end
end
