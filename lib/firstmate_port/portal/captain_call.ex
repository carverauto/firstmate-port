defmodule FirstmatePort.Portal.CaptainCall do
  @moduledoc """
  A bounded question firstmate put to the captain in Discord, and the answer.

  The crew asks; the captain picks. `options` is the whole of what may come
  back, so the answer is a value this row already listed - a Discord payload
  cannot introduce a new one. `allow_other` adds the one escape hatch, a modal
  the captain types into, and even that is only reachable on a call that asked
  for it.

  It is a table rather than process state for the same reason the inbox is
  (`docs/inbox.md`): a question the captain has not answered yet has to survive
  a restart, and the Discord message carrying it outlives any node. The
  `custom_id` on that message is this row's id, so an answer that arrives an
  hour later still lands on the question it was asked about.

  Answering is a one-way door: `:open` -> `:answered`, once. A second click on
  the same select is not a second order, and what enforces that is a filter
  carried into the UPDATE itself - not a read-then-write the two clicks could
  both pass. See `docs/captain-calls.md`.
  """

  import Ash.Expr
  require Ash.Query

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "captain_calls"
    repo FirstmatePort.Repo
  end

  code_interface do
    define :get, action: :by_id, args: [:id], not_found_error?: false
    define :ask, action: :ask
    define :delivered, action: :delivered
    define :undeliverable, action: :undeliverable
    define :answer, action: :answer
  end

  actions do
    defaults [:read]

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :ask do
      primary? true
      accept [:question, :options, :task, :channel_id, :allow_other]
      validate FirstmatePort.Portal.Validations.CaptainCallOptions
    end

    update :delivered do
      description "Discord accepted the message; this is the message it became."
      accept [:message_id]
      require_atomic? false
    end

    update :undeliverable do
      description """
      Discord would not take the message.

      The row stays rather than being deleted: an operator debugging a bot token
      or a channel id needs to see that the portal tried and what came back, and
      `/api/captain/calls` is where they look.
      """

      accept [:delivery_error]
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(status == :open))
      end

      change set_attribute(:status, :failed)
    end

    update :answer do
      description """
      Records the captain's pick. Only ever fires once.

      Atomic, and the filter is why: two clicks a millisecond apart both read an
      open call, and the write has to be the thing that decides between them. A
      read-then-write here would file the order twice.
      """

      accept [:answer, :answer_label, :answered_by]
      require_atomic? false

      # `Ash.Changeset.filter/2`, not the action-level `filter`: this updates a
      # record already loaded by id, and only a filter carried into the UPDATE
      # itself makes the write the thing that decides. A second click finds no
      # open row and gets `Ash.Error.Changes.StaleRecord`.
      change fn changeset, _context ->
        Ash.Changeset.filter(changeset, expr(status == :open))
      end

      change set_attribute(:status, :answered)
      change set_attribute(:answered_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Same wall as the inbox: the tenant, not the role. Firstmate asks as an
    # agent, the captain answers through a signed Discord interaction that the
    # endpoint has already resolved to one tenant.
    policy action_type([:read, :create, :update]) do
      authorize_if expr(tenant_slug == ^actor(:tenant_slug))
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_slug
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :question, :string do
      allow_nil? false
      public? true
      description "What the captain is being asked. Rendered as the Discord message body."
      # Discord refuses a message over 2000 characters, so a longer question
      # would be accepted here and then fail at the one place it matters.
      constraints min_length: 1, max_length: 2000
    end

    attribute :options, {:array, :map} do
      allow_nil? false
      public? true

      description """
      The bounded choices, as `%{"value" => _, "label" => _, "description" => _}`.
      Validated by `FirstmatePort.Portal.Validations.CaptainCallOptions`;
      Discord allows at most 25 in one select.
      """
    end

    attribute :task, :string do
      allow_nil? false
      public? true
      default "firstmate"

      description """
      The inbox task the answer is filed under, so the crew lane that asked is
      the one that reads the order back with `fm-steer inbox next --task`.
      """

      constraints min_length: 1, max_length: 200
    end

    attribute :channel_id, :string do
      allow_nil? false
      public? true
      description "Discord channel the question was posted to. Routing data, not a secret."
      constraints match: ~r/^[0-9]{1,32}$/
    end

    attribute :message_id, :string do
      default ""
      allow_nil? false
      public? true
      description "The Discord message the question became, once it has been posted."
      constraints max_length: 32, allow_empty?: true
    end

    attribute :allow_other, :boolean do
      default false
      allow_nil? false
      public? true
      description "Whether the select carries a 'Something else' choice that opens a modal."
    end

    attribute :status, :atom do
      constraints one_of: [:open, :answered, :failed]
      default :open
      allow_nil? false
      public? true
    end

    attribute :answer, :string do
      default ""
      allow_nil? false
      public? true
      description "The chosen option's value, or the captain's typed text on an 'other' answer."
      constraints max_length: 1000, allow_empty?: true, trim?: false
    end

    attribute :answer_label, :string do
      default ""
      allow_nil? false
      public? true
      description "The label the captain actually saw and clicked."
      constraints max_length: 100, allow_empty?: true
    end

    # Discord's own display name for whoever clicked. Not an identity this app
    # authenticated - it is whatever the verified payload said - so it is shown
    # as provenance and never used to authorize anything.
    attribute :answered_by, :string do
      default ""
      allow_nil? false
      public? true
      constraints max_length: 100, allow_empty?: true
    end

    attribute :answered_at, :utc_datetime_usec, public?: true

    attribute :delivery_error, :string do
      default ""
      allow_nil? false
      public? true
      description "Why Discord would not take the message. Status and reason, never the token."
      constraints max_length: 500, allow_empty?: true
    end

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9-]*$/
    end

    timestamps()
  end
end
