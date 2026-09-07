defmodule FirstmatePortWeb.DiscordEndpointPanelTest do
  @moduledoc """
  The panel that answers "Discord says my interactions endpoint could not be
  verified - why?" without anyone reading a pod log.

  `FirstmatePort.Discord.Attempts` is one process for the node and its entries
  outlive a test, so every test here signs in as its own freshly named tenant
  and the suite is not async: what a panel shows must be only what that test
  put there.
  """

  use FirstmatePortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Discord.Attempts

  @key String.duplicate("ab", 32)

  setup %{conn: conn} do
    tenant = "t#{System.unique_integer([:positive])}"
    {:ok, conn: sign_in(conn, human(tenant)), tenant: tenant}
  end

  defp human(slug) do
    {:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(
        %{
          email: "#{slug}-#{System.unique_integer([:positive])}@example.com",
          name: slug,
          tenant_slug: slug
        },
        authorize?: false
      )

    user
  end

  defp sign_in(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:guardian_token, token)
  end

  # `record/4` is a cast and the broadcast that follows it is what wakes the
  # LiveView, so a synchronous read is what makes the assertion deterministic:
  # once the tracker has answered, the LiveView's message is already queued.
  defp record(tenant, outcome, meta) do
    :ok = Attempts.record(tenant, outcome, meta)
    _ = Attempts.list(tenant)
    :ok
  end

  test "an endpoint with no key stored says so, in the words that fix it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/credentials")

    assert html =~ "Discord interactions endpoint"
    assert html =~ "Not stored"
    assert html =~ "every signed interaction for this tenant is refused"
    assert html =~ "Nothing has reached"
  end

  test "storing the key flips the panel without a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    html =
      view
      |> form("form[phx-submit=save]", %{"value" => @key})
      |> render_submit()

    assert html =~ "Interactions for this tenant verify against it"
    refute html =~ "every signed interaction for this tenant is refused"
  end

  test "a refusal appears as it happens, naming the check that failed",
       %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    :ok = record(tenant, :no_key, %{type: 1, application_id: "111111111111111111"})

    html = render(view)
    assert html =~ "PING"
    assert html =~ "no Discord public key stored"
  end

  test "a drifted clock is reported as a clock problem, not a key problem",
       %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    :ok = record(tenant, :stale_timestamp, %{type: 1, skew_seconds: 4000})

    html = render(view)
    assert html =~ "too far from now"
    assert html =~ "4000s ahead of"
  end

  test "a verified PING reads as success", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    :ok = record(tenant, :pong, %{type: 1, application_id: "111111111111111111"})

    assert render(view) =~ "answered PONG"
  end

  test "one tenant never sees another tenant's traffic", %{conn: conn, tenant: tenant} do
    other = "t#{System.unique_integer([:positive])}"
    _ = human(other)
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    :ok = record(other, :bad_signature, %{type: 1, application_id: "999999999999999999"})
    :ok = record(tenant, :pong, %{type: 1, application_id: "111111111111111111"})

    html = render(view)
    assert html =~ "answered PONG"
    refute html =~ "999999999999999999"
    refute html =~ "did not verify against the stored key"
  end
end
