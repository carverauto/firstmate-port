defmodule FirstmatePort.Events.EventLog do
  @moduledoc """
  Central AshEvents log for diagrams, rolls, progress, and no-mistakes runs.
  """

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Events,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table "event_logs"
    repo FirstmatePort.Repo
  end

  event_log do
    clear_records_for_replay(FirstmatePort.Events.ClearForReplay)
    primary_key_type(Ash.Type.UUIDv7)
    record_id_type(:string)
    persist_actor_primary_key(:user_id, FirstmatePort.Accounts.User)
  end

  multitenancy do
    strategy :context
  end
end
