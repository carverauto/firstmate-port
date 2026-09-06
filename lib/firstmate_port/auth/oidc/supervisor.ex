defmodule FirstmatePort.Auth.OIDC.Supervisor do
  @moduledoc """
  Owns the OIDC provider process so that a failed provider cannot stop the node.

  `ueberauth_oidcc` starts a provider for every entry in its `:issuers`
  application env, as a *permanent* child of its own application supervisor.
  A provider that cannot load its discovery document crashes there, exhausts the
  restart intensity, terminates the `:ueberauth_oidcc` application, and in a
  release takes the whole node with it — including `/healthz` and local sign-in,
  neither of which needs an identity provider.

  That is not hypothetical. `oidcc` retries a load that returns `{:error, _}`,
  but an *exception* escapes its `maybe` block and kills the process no matter
  how backoff is tuned. `httpc` raises exactly that way when it falls back to
  `public_key:cacerts_get/0` on an image with no CA bundle.

  So this app leaves `:ueberauth_oidcc`'s `:issuers` empty and starts the
  provider here instead, as a temporary child: a provider that dies is logged
  and left dead, and the portal keeps serving.
  """

  use Supervisor

  alias FirstmatePort.Auth.OIDC

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    cfg = Keyword.get_lazy(opts, :config, &OIDC.config/0)
    children = OIDC.child_specs(cfg)

    log_mode(cfg, children)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp log_mode(_cfg, []) do
    Logger.info(
      "OIDC disabled: no issuer configured. Sign-in uses local auth when LOCAL_AUTH is set."
    )
  end

  defp log_mode(cfg, [_child]) do
    Logger.info(
      "OIDC enabled: provider #{inspect(OIDC.provider_name(cfg))} for issuer #{OIDC.issuer(cfg)}"
    )
  end
end
