defmodule FirstmatePort.Jobs.Retention do
  @moduledoc "Drops job tick rows older than 30 days. Does not touch the Mac Bazel cache."

  def run do
    FirstmatePort.Repo.query!(
      "DELETE FROM job_ticks WHERE inserted_at < NOW() - INTERVAL '30 days'"
    )

    :ok
  end
end
