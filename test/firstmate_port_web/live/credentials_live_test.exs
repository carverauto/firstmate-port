defmodule FirstmatePortWeb.CredentialsLiveTest do
  use FirstmatePortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Credentials
  alias FirstmatePort.Credentials.Credential
  alias FirstmatePort.Tenancy

  @secret "ghp_a_real_looking_token_9999"

  setup %{conn: conn} do
    local = human("local")
    {:ok, conn: sign_in(conn, local), local: local, other: human("other")}
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

  test "stores a well-known slot and shows a hint instead of the secret", %{
    conn: conn,
    local: local
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    html =
      view
      |> form("#credential-form-0", %{
        "value" => String.duplicate("ab", 32),
        "description" => "ci"
      })
      |> render_submit()

    assert html =~ "discord/public_key"
    refute html =~ String.duplicate("ab", 32)
    assert html =~ "ci"

    assert {:ok, credential} = Credential.get_slot("discord", "public_key", Tenancy.opts(local))
    assert credential.description == "ci"
  end

  test "rejects a Discord key of the wrong shape without storing it", %{conn: conn, local: local} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    html =
      view
      |> form("#credential-form-0", %{"value" => "nope"})
      |> render_submit()

    assert html =~ "64 hex characters"
    assert {:ok, nil} = Credential.get_slot("discord", "public_key", Tenancy.opts(local))
  end

  test "a rejected secret is never echoed back into the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    view |> element("form[phx-change='select_slot']") |> render_change(%{"slot" => "custom"})

    too_long = String.duplicate("z", 9000)

    html =
      view
      |> form("#credential-form-0", %{
        "provider" => "stripe",
        "key" => "api_key",
        "value" => too_long
      })
      |> render_submit()

    refute html =~ "zzzz"
    assert html =~ "8192"
  end

  test "stores a slot of the tenant's own naming", %{conn: conn, local: local} do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    view |> element("form[phx-change='select_slot']") |> render_change(%{"slot" => "custom"})

    html =
      view
      |> form("#credential-form-0", %{
        "provider" => "stripe",
        "key" => "api_key",
        "value" => "sk_live_wxyz"
      })
      |> render_submit()

    assert html =~ "stripe/api_key"
    refute html =~ "sk_live_wxyz"
    assert {:ok, "sk_live_wxyz"} = Credentials.secret(local, "stripe", "api_key")
  end

  test "rotates and then deletes a stored slot", %{conn: conn, local: local} do
    {:ok, _} =
      Credential.create(%{provider: "github", key: "token", value: @secret}, Tenancy.opts(local))

    {:ok, view, html} = live(conn, ~p"/settings/credentials")
    assert html =~ "github/token"
    refute html =~ @secret

    html =
      view
      |> form("#rotate-github-token-0", %{"value" => "ghp_second_value_aaaa"})
      |> render_submit()

    assert html =~ "aaaa"
    assert {:ok, "ghp_second_value_aaaa"} = Credentials.secret(local, "github", "token")

    html =
      view
      |> element("button[phx-value-provider='github'][phx-value-key='token']")
      |> render_click()

    assert html =~ "Nothing stored yet"
    refute has_element?(view, "form[phx-submit='rotate']")
    assert {:ok, nil} = Credential.get_slot("github", "token", Tenancy.opts(local))
  end

  test "another tenant's credentials are not listed", %{conn: conn, other: other} do
    {:ok, _} =
      Credential.create(
        %{provider: "stripe", key: "api_key", value: "sk_live_other"},
        Tenancy.opts(other)
      )

    {:ok, _view, html} = live(conn, ~p"/settings/credentials")

    refute html =~ "stripe/api_key"
    assert html =~ "Nothing stored yet"
  end

  test "signed-out visitors are sent to login" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/settings/credentials")
  end
end
