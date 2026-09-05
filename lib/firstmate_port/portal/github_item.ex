defmodule FirstmatePort.Portal.GithubItem do
  @moduledoc """
  Open PRs and issues with firstmate assignment and GitHub check/BuildBuddy URLs.
  html_url and details_url are stored as copied from GitHub, never assembled.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "github_items"
    repo FirstmatePort.Repo
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at])
  end

  events do
    event_log(FirstmatePort.Events.EventLog)
    only_actions([:upsert, :assign])
  end

  code_interface do
    define :list, action: :read
    define :list_open_prs, action: :open_prs
    define :list_open_issues, action: :open_issues
    define :upsert, action: :upsert
    define :assign, action: :assign
  end

  actions do
    defaults [:read]

    read :open_prs do
      filter expr(kind == :pr and state == :open)
    end

    read :open_issues do
      filter expr(kind == :issue and state == :open)
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_html_url

      accept [
        :kind,
        :html_url,
        :title,
        :state,
        :check_status,
        :buildbuddy_url,
        :github_updated_at,
        :firewall_verdict
      ]

      change FirstmatePort.Changes.AssignPublicId
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :html_url, required?: true}
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :buildbuddy_url, required?: false}
    end

    update :assign do
      accept [:assignment_task_id, :assignment_worker, :assignment_status]

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(changeset, :assignment_updated_at, DateTime.utc_now())
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action([:upsert, :assign]) do
      authorize_if expr(^actor(:role) == :agent)
    end
  end

  multitenancy do
    strategy :context
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints min_length: 4, max_length: 64
    end

    attribute :kind, :atom do
      constraints one_of: [:pr, :issue]
      allow_nil? false
      public? true
    end

    attribute :html_url, :string do
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :state, :atom do
      constraints one_of: [:open, :closed]
      default :open
      public? true
    end

    attribute :check_status, :atom do
      constraints one_of: [:none, :queued, :running, :success, :failure]
      default :none
      public? true
    end

    attribute :buildbuddy_url, :string do
      default ""
      public? true
    end

    attribute :github_updated_at, :utc_datetime_usec, public?: true

    attribute :assignment_task_id, :string, public?: true
    attribute :assignment_worker, :string, public?: true
    attribute :assignment_status, :string, public?: true
    attribute :assignment_updated_at, :utc_datetime_usec, public?: true

    attribute :firewall_verdict, :atom do
      constraints one_of: [:none, :allowed, :blocked]
      default :none
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_html_url, [:html_url]
  end
end
