defmodule FirstmatePort.Portal.InboxMessage do
  @moduledoc """
  One message passed between firstmate, the second mate, and the crew.

  This is the store behind `fm-steer inbox`: every order and every "this is
  done" that goes through the CLI lands in a row the portal can render, so the
  captain can watch the traffic on the site. It is reached over the HTTP API and
  nothing else; firstmate keeps its own on-disk inbox and status files, which
  this neither reads nor replaces.

  Queue state is not history. `claim` and `ack` move a message's delivery
  status; the message itself - who sent it, when, and what it said - is written
  once and never rewritten.

  There is one inbox per tenant, not one per direction. `task` is the routing
  key: `firstmate` (`FirstmatePort.Inbox.default_task/0`) is the mailbox
  firstmate itself reads, and any other value addresses a crew lane. A message
  is `:pending` until a reader claims it with `next`, `:delivered` while that
  reader works, and `:acked` once they confirm it. Acked rows are kept rather
  than deleted - the history is the point.

  Claiming is `FOR UPDATE SKIP LOCKED` inside a transaction, so two crew members
  polling `next` at the same time cannot be handed the same order.
  """

  import Ash.Expr
  require Ash.Query

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Portal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "inbox_messages"
    repo FirstmatePort.Repo

    custom_indexes do
      # `next` is a poll: it runs far more often than a message arrives, and it
      # only ever looks at pending rows for one tenant. Partial, so the index
      # stays the size of the backlog rather than the size of the history.
      index [:tenant_slug, :seq],
        name: "inbox_messages_pending_index",
        where: "status = 'pending'"
    end
  end

  code_interface do
    define :recent, action: :recent
    define :open, action: :open
    define :get_by_ack, action: :by_ack, args: [:ack], not_found_error?: false
    define :put, action: :put
    define :claim, action: :claim
    define :ack, action: :ack
  end

  actions do
    defaults [:read]

    read :recent do
      description "Newest first, for the portal. Everything, acked rows included."
      argument :task, :string, allow_nil?: true
      filter expr(is_nil(^arg(:task)) or ^arg(:task) == "" or task == ^arg(:task))
      prepare build(sort: [seq: :desc], limit: 200)
    end

    read :open do
      description "What is still outstanding: what `fm-steer inbox list` shows."
      argument :task, :string, allow_nil?: true

      filter expr(
               status in [:pending, :delivered] and
                 (is_nil(^arg(:task)) or ^arg(:task) == "" or task == ^arg(:task))
             )

      prepare build(sort: [seq: :asc])
    end

    read :by_ack do
      description "The row an ack token names. The token is the row id."
      get? true
      argument :ack, :string, allow_nil?: false
      filter expr(id == ^arg(:ack))
    end

    read :claimable do
      description """
      The next unclaimed message, locked for the caller.

      `FOR UPDATE SKIP LOCKED` is what makes `next` safe to poll from more than
      one crewmate, or more than one portal node: a row another transaction is
      already claiming is skipped rather than handed out twice.
      """

      argument :task, :string, allow_nil?: true

      filter expr(
               status == :pending and
                 (is_nil(^arg(:task)) or ^arg(:task) == "" or task == ^arg(:task))
             )

      prepare build(sort: [seq: :asc], limit: 1, lock: "FOR UPDATE SKIP LOCKED")
    end

    create :put do
      primary? true
      accept [:task, :body, :delivery, :seq]

      change fn changeset, context ->
        Ash.Changeset.force_change_attribute(changeset, :sender, sender(context.actor))
      end
    end

    update :claim do
      description "Hands the message to the reader that called `next`."
      accept []
      require_atomic? false
      change set_attribute(:status, :delivered)
      change set_attribute(:delivered_at, &DateTime.utc_now/0)

      change fn changeset, context ->
        Ash.Changeset.force_change_attribute(changeset, :claimed_by, sender(context.actor))
      end
    end

    update :ack do
      description "The reader confirming they are done with it."
      accept []
      require_atomic? false
      change set_attribute(:status, :acked)
      change set_attribute(:acked_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Both sides of every conversation write here: the captain and firstmate as
    # humans, the crew as agents. The wall is the tenant, not the role.
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

    attribute :seq, :integer do
      allow_nil? false
      public? true
      description "Per-tenant message number, for ordering and for talking about a message."
    end

    attribute :task, :string do
      allow_nil? false
      public? true
      description "Routing key. `firstmate` is firstmate's own mailbox."
      constraints min_length: 1, max_length: 200
    end

    attribute :body, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 65_536
    end

    attribute :delivery, :string do
      default ""
      allow_nil? false
      public? true
      description "Free-form hint about how the reader should surface it, e.g. a Discord channel."
      constraints max_length: 500, allow_empty?: true
    end

    attribute :sender, :string do
      default ""
      allow_nil? false
      public? true
      description "Who filed it, so the portal can show which mate is talking."
      constraints max_length: 320, allow_empty?: true
    end

    attribute :claimed_by, :string do
      default ""
      allow_nil? false
      public? true
      description "Who took it off the queue with `next`."
      constraints max_length: 320, allow_empty?: true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :delivered, :acked]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :delivered_at, :utc_datetime_usec, public?: true
    attribute :acked_at, :utc_datetime_usec, public?: true

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 63, match: ~r/^[a-z][a-z0-9-]*$/
    end

    timestamps()
  end

  identities do
    identity :unique_seq, [:tenant_slug, :seq]
  end

  defp sender(%{email: email}) when not is_nil(email), do: to_string(email)
  defp sender(_), do: ""
end
