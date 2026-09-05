defmodule FirstmatePort.Events.ClearForReplay do
  @moduledoc false
  use AshEvents.ClearRecordsForReplay, otp_app: :firstmate_port

  @impl true
  def clear_records!(_opts) do
    repo = FirstmatePort.Repo

    Enum.each(
      ["diagrams", "progress_items", "rolls", "no_mistakes_runs", "github_items"],
      &repo.query!("TRUNCATE TABLE #{&1} CASCADE")
    )

    :ok
  end
end
