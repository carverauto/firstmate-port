defmodule FirstmatePort.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before anything opens a TLS socket: a node with no CA bundle must fail
    # legibly rather than raising out of public_key on first use.
    _ = FirstmatePort.Auth.CACerts.configure()

    children = [
      FirstmatePortWeb.Telemetry,
      # Before the Repo: nothing may read a credential row without the vault.
      FirstmatePort.Vault,
      FirstmatePort.Repo,
      {DNSCluster, query: Application.get_env(:firstmate_port, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:firstmate_port, :ash_domains),
         Application.fetch_env!(:firstmate_port, Oban)
       )},
      {Phoenix.PubSub, name: FirstmatePort.PubSub},
      FirstmatePort.Inbox,
      FirstmatePort.NATS.Supervisor,
      FirstmatePort.Auth.OIDC.Supervisor,
      FirstmatePortWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FirstmatePort.Supervisor]
    result = Supervisor.start_link(children, opts)
    _ = FirstmatePort.Accounts.Bootstrap.ensure_agent!()
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FirstmatePortWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
