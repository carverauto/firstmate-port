defmodule FirstmatePortWeb.UsageControllerTest do
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Portal.UsageSnapshot

  setup do
    token = "fmh_test_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, agent} =
      User.bootstrap_agent(
        %{
          email: "usage-agent@localhost",
          name: "usage agent",
          hashed_api_key: User.hash_token(token)
        },
        authorize?: false
      )

    other_token = "fmh_test_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, _other} =
      User.bootstrap_agent(
        %{
          email: "usage-other@localhost",
          name: "other",
          hashed_api_key: User.hash_token(other_token),
          tenant_slug: "other-tenant"
        },
        authorize?: false
      )

    {:ok, token: token, other_token: other_token, agent: agent}
  end

  defp auth(conn, token) do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  test "record then list shows computed remaining and status", %{conn: conn, token: token} do
    conn =
      auth(conn, token)
      |> post(~p"/api/usage", %{
        "provider" => "openrouter",
        "label" => "captain",
        "unit" => "usd",
        "allowance" => 100.0,
        "used" => 25.0,
        "window" => "monthly",
        "spend_priority" => 10
      })

    created = json_response(conn, 200)
    assert created["remaining"] == 75.0
    assert created["status"] == "ok"

    conn = auth(build_conn(), token) |> get(~p"/api/usage")
    body = json_response(conn, 200)
    assert body["tenant"] == "local"
    assert [%{"provider" => "openrouter", "label" => "captain"}] = body["data"]
    [row] = body["data"]
    assert row["remaining"] == 75.0
    assert row["pct_used"] == 0.25
    assert row["spend_priority"] == 10
    assert row["runway_days"] == nil
  end

  test "an agent reading keeps the configured allowance, window and spend priority", %{
    conn: conn,
    token: token
  } do
    auth(conn, token)
    |> post(~p"/api/usage", %{
      "provider" => "openrouter",
      "label" => "captain",
      "unit" => "usd",
      "allowance" => 100.0,
      "used" => 10.0,
      "window" => "weekly",
      "spend_priority" => 10,
      "notes" => "captain key"
    })

    reading =
      auth(build_conn(), token)
      |> post(~p"/api/usage", %{"provider" => "openrouter", "label" => "captain", "used" => 42.0})
      |> json_response(200)

    assert reading["used"] == 42.0
    assert reading["allowance"] == 100.0
    assert reading["remaining"] == 58.0
    assert reading["status"] == "ok"
    assert reading["spend_priority"] == 10
    assert reading["window"] == "weekly"

    [row] =
      auth(build_conn(), token)
      |> get(~p"/api/usage")
      |> json_response(200)
      |> Map.get("data")

    assert row["allowance"] == 100.0
    assert row["spend_priority"] == 10
    assert row["window"] == "weekly"
    assert row["used"] == 42.0
  end

  test "usage is tenant-scoped", %{conn: conn, token: token, other_token: other_token} do
    auth(conn, token)
    |> post(~p"/api/usage", %{"provider" => "openrouter", "label" => "local-only"})

    local_labels =
      auth(build_conn(), token) |> get(~p"/api/usage") |> json_response(200) |> Map.get("data")

    assert Enum.map(local_labels, & &1["label"]) == ["local-only"]

    other_rows =
      auth(build_conn(), other_token) |> get(~p"/api/usage") |> json_response(200)

    assert other_rows["tenant"] == "other-tenant"
    assert other_rows["data"] == []
  end

  test "invalid record is unprocessable", %{conn: conn, token: token} do
    conn = auth(conn, token) |> post(~p"/api/usage", %{"provider" => "", "label" => ""})
    assert json_response(conn, 422)
  end

  test "non-scalar numbers, priorities and timestamps are ignored, not crashes", %{
    conn: conn,
    token: token
  } do
    body =
      auth(conn, token)
      |> post(~p"/api/usage", %{
        "provider" => "openrouter",
        "label" => "captain",
        "allowance" => true,
        "spend_priority" => %{},
        "reset_at" => 123
      })
      |> json_response(200)

    assert body["allowance"] == nil
    assert body["status"] == "unknown"
    assert body["spend_priority"] == 100
    assert body["reset_at"] == nil
  end

  test "posted readings build the history runway needs", %{
    conn: conn,
    token: token,
    agent: agent
  } do
    auth(conn, token)
    |> post(~p"/api/usage", %{
      "provider" => "anthropic",
      "label" => "direct",
      "allowance" => 100.0,
      "used" => 10.0
    })

    auth(build_conn(), token)
    |> post(~p"/api/usage", %{"provider" => "anthropic", "label" => "direct", "used" => 40.0})

    [row] =
      auth(build_conn(), token) |> get(~p"/api/usage") |> json_response(200) |> Map.get("data")

    {:ok, snaps} = UsageSnapshot.for_account(row["id"], FirstmatePort.Tenancy.opts(agent))

    assert snaps |> Enum.map(& &1.used) |> Enum.sort() == [10.0, 40.0]
  end

  test "a post that only configures the account records no reading", %{
    conn: conn,
    token: token,
    agent: agent
  } do
    auth(conn, token)
    |> post(~p"/api/usage", %{
      "provider" => "anthropic",
      "label" => "config-only",
      "allowance" => 100.0,
      "spend_priority" => 5
    })

    [row] =
      auth(build_conn(), token)
      |> get(~p"/api/usage")
      |> json_response(200)
      |> Map.get("data")
      |> Enum.filter(&(&1["label"] == "config-only"))

    {:ok, snaps} = UsageSnapshot.for_account(row["id"], FirstmatePort.Tenancy.opts(agent))
    assert snaps == []
  end

  test "unauthenticated usage is rejected", %{conn: conn} do
    assert json_response(get(conn, ~p"/api/usage"), 401)["error"] == "unauthorized"
  end
end
