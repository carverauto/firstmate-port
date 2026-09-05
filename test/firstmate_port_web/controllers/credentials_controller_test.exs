defmodule FirstmatePortWeb.Api.CredentialsControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Credentials
  alias FirstmatePort.Tenancy

  @secret "ghp_a_real_looking_token_9999"

  setup do
    {:ok, local: human("local"), other: human("other")}
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

  defp agent(slug) do
    token = "fmh_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, _} =
      User.bootstrap_agent(
        %{
          email: "agent-#{System.unique_integer([:positive])}@example.com",
          name: "agent",
          hashed_api_key: User.hash_token(token),
          tenant_slug: slug
        },
        authorize?: false
      )

    token
  end

  defp as(conn, %User{} = user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{"tenant" => user.tenant_slug})
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp as(conn, token) when is_binary(token) do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  test "a tenant stores, lists, rotates and deletes its own slot", %{conn: conn, local: local} do
    created =
      conn
      |> as(local)
      |> post(~p"/api/credentials", %{
        "provider" => "github",
        "key" => "token",
        "value" => @secret,
        "description" => "ci"
      })
      |> json_response(201)

    assert created["provider"] == "github"
    assert created["tenant"] == "local"
    assert created["hint"] == "9999"
    assert created["value_bytes"] == byte_size(@secret)
    refute created["rotated_at"]
    refute Map.has_key?(created, "value")

    listed = conn |> as(local) |> get(~p"/api/credentials") |> json_response(200)
    assert [%{"provider" => "github", "key" => "token"}] = listed["data"]
    refute inspect(listed) =~ @secret

    rotated =
      conn
      |> as(local)
      |> put(~p"/api/credentials/github/token", %{"value" => "ghp_second_value_aaaa"})
      |> json_response(200)

    assert rotated["rotated_at"]
    assert rotated["hint"] == "aaaa"
    assert {:ok, "ghp_second_value_aaaa"} = Credentials.secret(local, "github", "token")

    assert conn |> as(local) |> delete(~p"/api/credentials/github/token") |> response(204)
    assert %{"data" => []} = conn |> as(local) |> get(~p"/api/credentials") |> json_response(200)
  end

  test "rotating without a note leaves the note alone, and PATCH edits it", %{
    conn: conn,
    local: local
  } do
    conn
    |> as(local)
    |> post(~p"/api/credentials", %{
      "provider" => "github",
      "key" => "token",
      "value" => @secret,
      "description" => "ci"
    })
    |> json_response(201)

    rotated =
      conn
      |> as(local)
      |> put(~p"/api/credentials/github/token", %{"value" => "ghp_second_value_aaaa"})
      |> json_response(200)

    assert rotated["description"] == "ci"

    patched =
      conn
      |> as(local)
      |> patch(~p"/api/credentials/github/token", %{"description" => "release bot"})
      |> json_response(200)

    assert patched["description"] == "release bot"
    assert patched["hint"] == "aaaa"
    # The note edit does not disturb the secret.
    assert {:ok, "ghp_second_value_aaaa"} = Credentials.secret(local, "github", "token")
  end

  test "PATCH on an empty slot is 404", %{conn: conn, local: local} do
    assert conn
           |> as(local)
           |> patch(~p"/api/credentials/github/token", %{"description" => "nope"})
           |> json_response(404)
  end

  test "put creates a slot that does not exist yet", %{conn: conn, local: local} do
    body =
      conn
      |> as(local)
      |> put(~p"/api/credentials/stripe/api_key", %{"value" => "sk_live_zzzz"})
      |> json_response(200)

    assert body["provider"] == "stripe"
    assert {:ok, "sk_live_zzzz"} = Credentials.secret(local, "stripe", "api_key")
  end

  test "a tenant never sees another tenant's slots", %{conn: conn, local: local, other: other} do
    conn
    |> as(local)
    |> post(~p"/api/credentials", %{"provider" => "github", "key" => "token", "value" => @secret})
    |> json_response(201)

    assert %{"data" => []} = conn |> as(other) |> get(~p"/api/credentials") |> json_response(200)

    assert conn
           |> as(other)
           |> delete(~p"/api/credentials/github/token")
           |> json_response(404)

    # The row survives the other tenant's delete attempt.
    assert {:ok, @secret} = Credentials.secret(local, "github", "token")
  end

  test "an agent credential cannot write", %{conn: conn} do
    body =
      conn
      |> as(agent("local"))
      |> post(~p"/api/credentials", %{
        "provider" => "github",
        "key" => "token",
        "value" => @secret
      })
      |> json_response(403)

    assert body["error"]
  end

  test "a bad Discord public key is refused with a usable message", %{conn: conn, local: local} do
    body =
      conn
      |> as(local)
      |> post(~p"/api/credentials", %{
        "provider" => "discord",
        "key" => "public_key",
        "value" => "nope"
      })
      |> json_response(422)

    assert body["error"] =~ "64 hex characters"
  end

  test "a rejected secret never comes back in the error", %{conn: conn, local: local} do
    too_long = String.duplicate("z", 9000)

    body =
      conn
      |> as(local)
      |> post(~p"/api/credentials", %{
        "provider" => "github",
        "key" => "token",
        "value" => too_long
      })
      |> json_response(422)

    refute body["error"] =~ "zzzz"
    assert body["error"] =~ "8192"
  end

  test "a duplicate slot is refused without echoing the secret", %{conn: conn, local: local} do
    conn
    |> as(local)
    |> post(~p"/api/credentials", %{"provider" => "github", "key" => "token", "value" => @secret})
    |> json_response(201)

    body =
      conn
      |> as(local)
      |> post(~p"/api/credentials", %{
        "provider" => "github",
        "key" => "token",
        "value" => @secret
      })
      |> json_response(422)

    refute body["error"] =~ @secret
  end

  test "a malformed slot name is refused", %{conn: conn, local: local} do
    body =
      conn
      |> as(local)
      |> post(~p"/api/credentials", %{
        "provider" => "Not A Slug",
        "key" => "token",
        "value" => @secret
      })
      |> json_response(400)

    assert body["error"] =~ "provider"
  end

  test "a missing value is refused", %{conn: conn, local: local} do
    assert conn
           |> as(local)
           |> post(~p"/api/credentials", %{"provider" => "github", "key" => "token"})
           |> json_response(400)
  end

  test "signed-out requests are unauthorized", %{conn: conn} do
    assert conn
           |> put_req_header("accept", "application/json")
           |> get(~p"/api/credentials")
           |> json_response(401)
  end

  test "the slot catalogue is discoverable", %{conn: conn, local: local} do
    body = conn |> as(local) |> get(~p"/api/credentials/slots") |> json_response(200)

    assert Enum.any?(body["data"], &(&1["provider"] == "discord" and &1["key"] == "public_key"))
  end

  test "tenancy is taken from the actor, not the request", %{conn: conn, local: local} do
    created =
      conn
      |> as(local)
      |> put(~p"/api/credentials/github/token", %{"value" => @secret, "tenant" => "other"})
      |> json_response(200)

    assert created["tenant"] == "local"

    assert {:ok, nil} =
             FirstmatePort.Credentials.Credential.get_slot(
               "github",
               "token",
               Tenancy.opts(human("other"))
             )
  end
end
