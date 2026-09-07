defmodule FirstmatePort.Repo.Migrations.AddCaptainCalls do
  @moduledoc """
  The bounded questions firstmate puts to the captain in Discord, and their
  answers. See `FirstmatePort.Portal.CaptainCall` and `docs/captain-calls.md`.

  Hand-written: `mix ash.codegen` cannot snapshot this project while
  `FirstmatePort.Portal.ProgressItem` carries a `base_filter` without
  `base_filter_sql`, so every migration here is written the same way.
  """

  use Ecto.Migration

  def up do
    create table(:captain_calls, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :question, :text, null: false
      add :options, :map, null: false
      add :task, :text, null: false, default: "firstmate"
      add :channel_id, :text, null: false
      add :message_id, :text, null: false, default: ""
      add :allow_other, :boolean, null: false, default: false
      add :status, :text, null: false, default: "open"
      add :answer, :text, null: false, default: ""
      add :answer_label, :text, null: false, default: ""
      add :answered_by, :text, null: false, default: ""
      add :answered_at, :utc_datetime_usec
      add :delivery_error, :text, null: false, default: ""
      add :tenant_slug, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:captain_calls, [:tenant_slug, :inserted_at],
             name: "captain_calls_open_index",
             where: "status = 'open'"
           )
  end

  def down do
    drop_if_exists index(:captain_calls, [:tenant_slug, :inserted_at],
                     name: "captain_calls_open_index"
                   )

    drop table(:captain_calls)
  end
end
