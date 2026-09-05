defmodule FirstmatePort.Jobs.Tick do
  @moduledoc """
  AshOban scheduled actions: GitHub poll and retention.
  The workstation Bazel cache wipe stays on the Mac crontab.
  """

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Jobs,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban]

  postgres do
    table "job_ticks"
    repo FirstmatePort.Repo
  end

  oban do
    scheduled_actions do
      schedule :github_poll, "*/15 * * * *" do
        action :github_poll
        queue :github
        worker_module_name FirstmatePort.Jobs.Tick.AshOban.ActionWorker.GithubPoll
      end

      schedule :retention, "0 3 * * *" do
        action :retention
        queue :default
        worker_module_name FirstmatePort.Jobs.Tick.AshOban.ActionWorker.Retention
      end
    end
  end

  actions do
    defaults [:read]

    create :github_poll do
      accept []
      change set_attribute(:kind, :github_poll)
      change FirstmatePort.Jobs.GitHubPollChange
    end

    create :retention do
      accept []
      change set_attribute(:kind, :retention)
      change FirstmatePort.Jobs.RetentionChange
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      constraints one_of: [:github_poll, :retention]
      allow_nil? false
    end

    timestamps()
  end
end
