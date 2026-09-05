defmodule FirstmatePort.Portal.Diagram do
  @moduledoc "Interactive Archify HTML plus optional PNG/SVG share cards."

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshEvents.Events]

  postgres do
    table "diagrams"
    repo FirstmatePort.Repo
  end

  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    ignore_attributes([:inserted_at, :updated_at, :html, :png, :svg])
    attributes_as_attributes([:tenant_slug])
  end

  events do
    event_log(FirstmatePort.Events.EventLog)
    only_actions([:upload])
  end

  code_interface do
    define :get, action: :by_id, args: [:id]
    define :list, action: :index
    define :upload, action: :upload
  end

  actions do
    defaults [:read]

    read :index do
      prepare build(select: [:id, :title, :notes, :inserted_at, :updated_at])
    end

    read :by_id do
      get? true
      argument :id, :string, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :upload do
      primary? true
      accept [:id, :title, :notes, :html, :png, :svg]
      change FirstmatePort.Changes.AssignPublicId
      change {FirstmatePort.Changes.FanoutDiscord, kind: :diagram}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:upload) do
      authorize_if expr(^actor(:role) == :agent)
    end
  end

  validations do
    validate fn changeset, _ ->
      html = Ash.Changeset.get_attribute(changeset, :html)

      cond do
        is_nil(html) -> :ok
        byte_size(html) > 8 * 1024 * 1024 -> {:error, field: :html, message: "html exceeds 8MiB"}
        true -> :ok
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_slug
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints min_length: 4, max_length: 64, match: ~r/^[a-z0-9][a-z0-9-]{1,63}$/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :notes, :string do
      default ""
      public? true
    end

    attribute :html, :binary do
      allow_nil? false
    end

    attribute :png, :binary
    attribute :svg, :binary

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end
end
