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

  test "signed-in topbar holds theme, identity, and sign out in an avatar menu", %{
    conn: conn,
    local: local
  } do
    {:ok, _view, html} = live(conn, ~p"/settings/credentials")

    assert html =~ "account-menu"
    assert html =~ "gravatar.com/avatar/"
    assert html =~ to_string(local.email)
    assert html =~ "Sign out"
    assert html =~ "Color theme"
    refute html =~ ~s(<span class="who">)
  end

  describe "fleet-log embeddings" do
    test "a fresh tenant is told nothing is being sent anywhere", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/credentials")

      assert html =~ "Fleet-log embeddings"
      assert html =~ "Nothing from this fleet log is sent anywhere"
    end

    test "choosing a model without a key does not switch it on", %{conn: conn, local: local} do
      {:ok, view, _html} = live(conn, ~p"/settings/credentials")

      html =
        view
        |> form("form[phx-submit=set_embedding_model]", %{
          "model" => "openai:text-embedding-3-small"
        })
        |> render_submit()

      assert html =~ "Save an embeddings/api_key credential"

      assert {:ok, %Tenant{embedding_model: "openai:text-embedding-3-small"}} =
               Tenant.get_by_slug(Tenancy.slug(local), actor: local)
    end

    test "a model and a key together report it as on", %{conn: conn, local: local} do
      {:ok, _} =
        Credential.create(
          %{provider: "embeddings", key: "api_key", value: "sk-a-real-looking-key"},
          Tenancy.opts(local)
        )

      {:ok, view, _html} = live(conn, ~p"/settings/credentials")

      html =
        view
        |> form("form[phx-submit=set_embedding_model]", %{
          "model" => "google:gemini-embedding-001"
        })
        |> render_submit()

      assert html =~ "On, using google:gemini-embedding-001"
      refute html =~ "sk-a-real-looking-key"
    end

    test "a model spec the portal cannot use is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/credentials")

      html =
        view
        |> form("form[phx-submit=set_embedding_model]", %{"model" => "nonesuch:whatever"})
        |> render_submit()

      assert html =~ "provider this build cannot reach"
      assert html =~ "Nothing from this fleet log is sent anywhere"
    end
  end

  test "embedding status follows saving, rotating, and deleting the key", %{
    conn: conn,
    local: local
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/credentials")

    view
    |> form("form[phx-submit=set_embedding_model]", %{"model" => "openai:text-embedding-3-small"})
    |> render_submit()

    view
    |> element("form[phx-change=select_slot]")
    |> render_change(%{"slot" => "embeddings/api_key"})

    html = view |> form("#credential-form-0", %{"value" => "sk-first"}) |> render_submit()
    assert html =~ "On, using openai:text-embedding-3-small"

    {:ok, credential} = Credential.get_slot("embeddings", "api_key", Tenancy.opts(local))
    :ok = Credential.destroy(credential, Tenancy.opts(local))
    {:ok, remounted, html} = live(conn, ~p"/settings/credentials")
    assert html =~ "Save an embeddings/api_key credential"

    {:ok, _} =
      Credentials.put(
        %{provider: "embeddings", key: "api_key", value: "sk-second"},
        Tenancy.opts(local)
      )

    html =
      render_submit(remounted, "rotate", %{
        "provider" => "embeddings",
        "key" => "api_key",
        "value" => "sk-third"
      })

    assert html =~ "On, using openai:text-embedding-3-small"

    html = render_click(remounted, "delete", %{"provider" => "embeddings", "key" => "api_key"})
    assert html =~ "Save an embeddings/api_key credential"
    refute html =~ "On, using"
  end
end
