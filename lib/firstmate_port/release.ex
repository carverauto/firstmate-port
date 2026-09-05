defmodule FirstmatePort.Release do
  @moduledoc "Release tasks for Docker / Kubernetes. Not started as an OTP app child."
  @app :firstmate_port

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    seed_example_tenant()
  end

  defp seed_example_tenant do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(hd(repos()), fn _repo ->
        FirstmatePort.Accounts.Tenant.seed(
          %{slug: FirstmatePort.Tenancy.default_slug(), name: "Example"},
          authorize?: false
        )
      end)
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
