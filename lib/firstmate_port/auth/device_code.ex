defmodule FirstmatePort.Auth.DeviceCode do
  @moduledoc "RFC 8628 device authorization grant, stored in the public schema."

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_codes"
    repo FirstmatePort.Repo
  end

  code_interface do
    define :issue, action: :issue
    define :get_by_device, action: :by_device, args: [:device_code]
    define :get_by_user_code, action: :by_user_code, args: [:user_code]
    define :approve, action: :approve
    define :deny, action: :deny
  end

  actions do
    defaults [:read]

    read :by_device do
      get? true
      argument :device_code, :string, allow_nil?: false
      filter expr(device_code == ^arg(:device_code))
    end

    read :by_user_code do
      get? true
      argument :user_code, :string, allow_nil?: false
      filter expr(user_code == ^arg(:user_code))
    end

    create :issue do
      accept []
      change FirstmatePort.Auth.DeviceCode.Issue
    end

    update :approve do
      accept [:user_id, :tenant_slug]
      change set_attribute(:status, :approved)
    end

    update :deny do
      accept []
      change set_attribute(:status, :denied)
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :device_code, :string do
      allow_nil? false
    end

    attribute :user_code, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :approved, :denied]
      default :pending
      allow_nil? false
    end

    attribute :user_id, :uuid
    attribute :tenant_slug, :string
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :interval, :integer, default: 5, allow_nil?: false

    timestamps()
  end

  identities do
    identity :unique_device_code, [:device_code]
    identity :unique_user_code, [:user_code]
  end
end
