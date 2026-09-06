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

    # AshOban scheduled workers run their target through Ash.ActionInput,
    # which only resolves generic actions. Pointing a schedule at a
    # create/update/destroy action discards every tick with NoSuchAction,
    # so these stay generic and call the job modules directly.
    action :github_poll, :atom do
      run fn _input, context ->
        :ok = FirstmatePort.Jobs.GitHubPoll.run(context.actor)
        {:ok, :ok}
      end
    end

    action :retention, :atom do
      run fn _input, _ ->
        :ok = FirstmatePort.Jobs.Retention.run()
        {:ok, :ok}
      end
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
