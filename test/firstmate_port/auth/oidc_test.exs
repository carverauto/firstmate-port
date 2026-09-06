defmodule FirstmatePort.Auth.OIDCTest do
  @moduledoc """
  OIDC is optional in every runtime. Nothing here may take the node down.
  """
  use ExUnit.Case, async: true

  alias FirstmatePort.Auth.OIDC

  describe "provider identity" do
    test "the issuer process name is generic, not a vendor name" do
      assert OIDC.provider_name() == :firstmate_oidc
    end

    test "the ueberauth strategy points at the generic issuer name" do
      providers = Application.get_env(:ueberauth, Ueberauth)[:providers]
      {Ueberauth.Strategy.Oidcc, opts} = providers[:oidc]

      assert opts[:issuer] == OIDC.provider_name()
    end

    test "ueberauth_oidcc is never handed an issuer to supervise" do
      # Its application supervisor starts each configured issuer as a permanent
      # child. A provider that dies there terminates :ueberauth_oidcc and, in a
      # release, the whole node. This app owns the provider instead.
      assert Application.get_env(:ueberauth_oidcc, :issuers) == []
    end
  end

  describe "configured?/1" do
    test "false when no issuer is set" do
      refute OIDC.configured?(issuer: nil, client_id: "id", client_secret: "secret")
      refute OIDC.configured?(issuer: "", client_id: "id", client_secret: "secret")
    end

    test "false when the client credentials are incomplete" do
      refute OIDC.configured?(
               issuer: "https://idp.example.com",
               client_id: nil,
               client_secret: "s"
             )

      refute OIDC.configured?(
               issuer: "https://idp.example.com",
               client_id: "id",
               client_secret: nil
             )
    end

    test "true for any issuer with a full client credential" do
      assert OIDC.configured?(
               issuer: "https://keycloak.example.com/realms/main",
               client_id: "firstmate-port",
               client_secret: "secret"
             )
    end

    test "an issuer can be derived from a discovery url alone" do
      cfg = [
        discovery_url: "https://idp.example.com/o/fm/.well-known/openid-configuration",
        client_id: "id",
        client_secret: "secret"
      ]

      assert OIDC.configured?(cfg)
      assert OIDC.issuer(cfg) == "https://idp.example.com/o/fm/"
    end
  end

  describe "child_specs/1" do
    test "no provider is started when OIDC is unconfigured" do
      assert OIDC.child_specs(issuer: nil) == []
    end

    test "a configured provider is started as a temporary child" do
      cfg = [issuer: "https://idp.example.com", client_id: "id", client_secret: "secret"]

      assert [spec] = OIDC.child_specs(cfg)

      assert spec.restart == :temporary,
             "a provider that dies must not be restarted into a crash loop"
    end
  end

  describe "fail-soft supervision" do
    @tag :capture_log
    test "a provider whose configuration load raises does not take the node down" do
      # Reproduces the reported boot crash: the provider GenServer dies during
      # {:continue, :load_configuration} because loading raised rather than
      # returning {:error, _}. oidcc's backoff only catches error tuples, so the
      # exception escapes and kills the process no matter how backoff is tuned.
      # Upstream: httpc's ssl option default calls public_key:cacerts_get/0,
      # which raises FunctionClauseError (not a clean error) when the container
      # has no OS CA bundle.
      name = :"oidc_raising_#{System.unique_integer([:positive])}"

      cfg = [
        issuer: "https://idp.example.com",
        client_id: "id",
        client_secret: "secret",
        provider_name: name,
        provider_configuration_opts: %{
          request_opts: %{http_adapter: {__MODULE__.RaisingAdapter, %{}}}
        }
      ]

      # Trap exits so a supervisor that gives up cannot take the test with it —
      # in a release that link is what reaches the application controller.
      Process.flag(:trap_exit, true)

      {:ok, sup} = OIDC.Supervisor.start_link(config: cfg, name: nil)
      sup_ref = Process.monitor(sup)

      provider_ref = Process.monitor(Process.whereis(name))
      assert_receive {:DOWN, ^provider_ref, :process, _pid, _reason}, 5_000

      # The supervisor outlives the dead provider. A provider restarted into a
      # crash loop would instead exhaust the restart intensity and bring the
      # supervisor — and every tree above it — down within this window.
      refute_receive {:DOWN, ^sup_ref, :process, _, _}, 1_000
      assert Process.alive?(sup)
      assert Process.whereis(name) == nil
      refute OIDC.ready?(name)

      Supervisor.stop(sup)
    end

    @tag :capture_log
    test "the app supervision tree starts with an unreachable issuer configured" do
      cfg = [
        issuer: "https://idp.invalid",
        client_id: "id",
        client_secret: "secret",
        provider_name: :"oidc_unreachable_#{System.unique_integer([:positive])}"
      ]

      Process.flag(:trap_exit, true)
      assert {:ok, sup} = OIDC.Supervisor.start_link(config: cfg, name: nil)
      assert Process.alive?(sup)
      Supervisor.stop(sup)
    end
  end

  describe "ready?/1" do
    test "discovery alone stays unavailable until signing keys are loaded" do
      name = :"oidc_partial_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      table = :ets.new(name, [:named_table, :protected])

      cfg = [
        issuer: "https://idp.example.test",
        client_id: "portal",
        client_secret: "secret",
        provider_name: name
      ]

      configuration = %Oidcc.ProviderConfiguration{issuer: cfg[:issuer]}

      :ets.insert(
        table,
        {:provider_configuration, Oidcc.ProviderConfiguration.struct_to_record(configuration)}
      )

      refute OIDC.ready?(name)
      refute OIDC.enabled?(cfg)
      assert OIDC.status(cfg) == :unavailable

      jwks = JOSE.JWK.from_map(%{"kty" => "oct", "k" => Base.url_encode64("test-signing-key")})
      :ets.insert(table, {:jwks, JOSE.JWK.to_record(jwks)})

      assert OIDC.ready?(name)
      assert OIDC.enabled?(cfg)
      assert OIDC.status(cfg) == :ready

      :ets.delete(table)
      refute OIDC.ready?(name)
      assert OIDC.status(cfg) == :unavailable
    end

    test "false when no provider process is running" do
      refute OIDC.ready?(:"oidc_never_started_#{System.unique_integer([:positive])}")
    end
  end

  defmodule RaisingAdapter do
    @moduledoc false
    # Stands in for httpc raising out of public_key:cacerts_get/0.
    def request(_method, _request, _http_opts, _opts, _config) do
      raise FunctionClauseError,
        module: :pubkey_os_cacerts,
        function: :conv_error_reason,
        arity: 1
    end
  end
end
