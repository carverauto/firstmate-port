defmodule FirstmatePort.Portal.NoMistakesRun do
  @moduledoc """
  no-mistakes pipeline events posted by firstmate. The daemon stays on the Mac.
  Findings and logs stay on the LAN portal. Public/Discord surfaces stay generic.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "no_mistakes_runs"
    repo FirstmatePort.Repo
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at, :logs, :findings])
  end

  events do
    event_log(FirstmatePort.Events.EventLog)
    only_actions([:record, :human_respond])
  end

  code_interface do
    define :get, action: :by_id, args: [:id]
    define :list, action: :read
    define :record, action: :record
    define :human_respond, action: :human_respond
  end

  actions do
    defaults [:read]

    read :by_id do
      get? true
      argument :id, :string, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :record do
      primary? true
      upsert? true
      upsert_identity :unique_run_id

      upsert_fields [
        :branch,
        :step,
        :findings,
        :pr_url,
        :outcome,
        :intent,
        :logs,
        :public_summary,
        :firewall_verdict
      ]

      accept [
        :run_id,
        :branch,
        :step,
        :findings,
        :pr_url,
        :outcome,
        :intent,
        :logs,
        :public_summary,
        :firewall_verdict
      ]

      change FirstmatePort.Changes.AssignPublicId
      validate {FirstmatePort.Validations.HttpsUrl, attribute: :pr_url, required?: false}
      change {FirstmatePort.Changes.FanoutDiscord, kind: :no_mistakes}
    end

    update :human_respond do
      accept [:respond_action, :respond_findings, :respond_instructions]

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(changeset, :respond_at, DateTime.utc_now())
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:record) do
      authorize_if expr(^actor(:role) == :agent)
    end

    policy action(:human_respond) do
      authorize_if actor_present()
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

    attribute :run_id, :string do
      allow_nil? false
      public? true
    end

    attribute :branch, :string do
      allow_nil? false
      public? true
    end

    attribute :step, :string do
      default ""
      public? true
    end

    attribute :findings, :string do
      default ""
      public? true
    end

    attribute :pr_url, :string do
      default ""
      public? true
    end

    attribute :outcome, :string do
      default ""
      public? true
    end

    attribute :intent, :string do
      default ""
      public? true
    end

    attribute :logs, :string do
      default ""
      public? true
    end

    attribute :public_summary, :string do
      default ""
      public? true
    end

    attribute :firewall_verdict, :atom do
      constraints one_of: [:none, :allowed, :blocked]
      default :none
      public? true
    end

    attribute :respond_action, :string do
      default ""
      public? true
    end

    attribute :respond_findings, :string do
      default ""
      public? true
    end

    attribute :respond_instructions, :string do
      default ""
      public? true
    end

    attribute :respond_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_run_id, [:run_id]
  end
end
