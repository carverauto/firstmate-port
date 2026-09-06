defmodule FirstmatePort.Auth.OIDC do
  @moduledoc """
  Generic OIDC relying-party configuration.

  Any spec-compliant provider works: Keycloak, Dex, Google, Okta, Entra, and the
  rest. The portal carries no per-vendor knowledge. Everything but the issuer,
  client id, and client secret is read from the issuer's discovery document at
  runtime, so adding a provider is configuration, not code.

  OIDC is optional in every runtime:

    * no issuer configured — the portal serves local sign-in when it is enabled,
      and otherwise says sign-in is not configured;
    * issuer configured but unavailable — the portal keeps serving, and sign-in
      falls back the same way. See `FirstmatePort.Auth.OIDC.Supervisor` for
      provider failure and retry semantics.

  `FirstmatePort.Auth.OIDC.Supervisor` owns the provider process; see its
  moduledoc for why this app, and not `ueberauth_oidcc`, starts it.
  """

  @provider_name :firstmate_oidc
  @well_known "/.well-known/openid-configuration"
  @default_scopes ~w(openid email profile)

  @doc """
  Registered name of the provider process.

  Deliberately generic: the portal is not an adapter for one vendor, and a
  vendor-shaped name here leaks into crash reports and operator muscle memory.
  """
  @spec provider_name() :: atom()
  def provider_name, do: @provider_name

  @spec provider_name(keyword()) :: atom()
  def provider_name(cfg), do: Keyword.get(cfg, :provider_name, @provider_name)

  @spec config() :: keyword()
  def config, do: Application.get_env(:firstmate_port, __MODULE__, [])

  @doc """
  Issuer URL, or `nil`.

  `oidcc` derives the discovery URL from the issuer, so the issuer is the
  authoritative setting. A lone `OIDC_DISCOVERY_URL` is still honoured by
  stripping the well-known suffix, which is what older deployments set.
  """
  @spec issuer(keyword()) :: String.t() | nil
  def issuer(cfg \\ config()) do
    trimmed(cfg[:issuer]) || issuer_from_discovery(cfg)
  end

  @spec client_id(keyword()) :: String.t() | nil
  def client_id(cfg \\ config()), do: trimmed(cfg[:client_id])

  @spec client_secret(keyword()) :: String.t() | nil
  def client_secret(cfg \\ config()), do: trimmed(cfg[:client_secret])

  @spec redirect_uri(keyword()) :: String.t() | nil
  def redirect_uri(cfg \\ config()), do: trimmed(cfg[:redirect_uri])

  @spec scopes(keyword()) :: [String.t()]
  def scopes(cfg \\ config()), do: Keyword.get(cfg, :scopes, @default_scopes)

  @doc "Whether enough is set to attempt a provider at all."
  @spec configured?(keyword()) :: boolean()
  def configured?(cfg \\ config()) do
    not is_nil(issuer(cfg)) and not is_nil(client_id(cfg)) and not is_nil(client_secret(cfg))
  end

  @doc """
  Whether the provider has discovery configuration and signing keys loaded.

  Reads the worker's own ETS table rather than calling it, so this is safe to
  ask on a request path and while the provider is down.
  """
  @spec ready?(atom()) :: boolean()
  def ready?(name \\ @provider_name) when is_atom(name) do
    with pid when is_pid(pid) <- Process.whereis(name),
         table when table != :undefined <- :ets.whereis(name),
         [_ | _] <- :ets.lookup(table, :provider_configuration),
         [_ | _] <- :ets.lookup(table, :jwks) do
      true
    else
      _ -> false
    end
  rescue
    # The worker can die between the lookups above, taking its table with it.
    _ -> false
  end

  @doc "Whether the portal should offer identity-provider sign-in right now."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(cfg \\ config()) do
    configured?(cfg) and ready?(provider_name(cfg))
  end

  @doc """
  What to tell an operator or a visitor about identity-provider sign-in.

    * `:disabled` — nothing configured; this is the default and not an error
    * `:unavailable` — configured, but the provider has no usable configuration
    * `:ready` — sign-in will work
  """
  @spec status(keyword()) :: :disabled | :unavailable | :ready
  def status(cfg \\ config()) do
    cond do
      not configured?(cfg) -> :disabled
      ready?(provider_name(cfg)) -> :ready
      true -> :unavailable
    end
  end

  @doc """
  The discovery document endpoints, when they are loaded.

  Endpoints come from the provider, never from a vendor-shaped URL template.
  """
  @spec provider_configuration(keyword()) :: {:ok, struct()} | :error
  def provider_configuration(cfg \\ config()) do
    name = provider_name(cfg)

    if ready?(name) do
      {:ok, Oidcc.ProviderConfiguration.Worker.get_provider_configuration(name)}
    else
      :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Child specs for the configured provider — `[]` when OIDC is not configured.

  The provider is `:temporary` on purpose. Its configuration load can fail for
  reasons that will not resolve by restarting (no CA bundle, a typo in the
  issuer), and a restart loop would take down whatever supervises it.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(cfg \\ config()) do
    if configured?(cfg), do: [provider_child_spec(cfg)], else: []
  end

  defp provider_child_spec(cfg) do
    name = provider_name(cfg)

    opts =
      %{
        name: name,
        issuer: issuer(cfg),
        # Retry transient failures (DNS, a provider still booting) rather than
        # requiring a pod restart. Exceptions escape this and kill the process,
        # which is why the child spec below is temporary.
        backoff_type: :random,
        backoff_min: :timer.seconds(1),
        backoff_max: :timer.minutes(5)
      }
      |> maybe_put(:provider_configuration_opts, cfg[:provider_configuration_opts])

    %{
      id: name,
      start: {Oidcc.ProviderConfiguration.Worker, :start_link, [opts]},
      restart: :temporary,
      type: :worker,
      shutdown: 5_000
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp issuer_from_discovery(cfg) do
    case trimmed(cfg[:discovery_url]) do
      nil -> nil
      url -> String.replace_suffix(url, @well_known, "/")
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_), do: nil
end
