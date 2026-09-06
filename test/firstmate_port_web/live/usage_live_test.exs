defmodule FirstmatePortWeb.UsageLiveTest do
  use FirstmatePortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Portal.UsageAccount

  setup %{conn: conn} do
    {:ok, user} =
      User.upsert_oidc(%{email: "usage-live@example.com", name: "Usage"}, authorize?: false)

    {:ok, jwt, _} = FirstmatePort.Auth.Guardian.encode_and_sign(user, %{})

    conn = init_test_session(conn, %{"guardian_token" => jwt})
    {:ok, conn: conn, user: user}
  end

  test "usage page lists accounts with remaining", %{conn: conn, user: user} do
    {:ok, _} =
      UsageAccount.record(
        %{provider: "openrouter", label: "captain", allowance: 100.0, used: 25.0},
        FirstmatePort.Tenancy.opts(user)
      )

    {:ok, _view, html} = live(conn, ~p"/usage")

    assert html =~ "openrouter / captain"
    assert html =~ "remaining 75.00"
  end

  test "usage page offers an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/usage")

    assert html =~ "No accounts yet"
  end

  test "saving the form adds an account", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> form("#usage-form", %{
        "account" => %{"provider" => "anthropic", "label" => "direct", "allowance" => "50"}
      })
      |> render_submit()

    assert html =~ "anthropic / direct"
  end

  test "re-saving an account keeps its configured unit and window", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/usage")

    view
    |> form("#usage-form", %{
      "account" => %{
        "provider" => "anthropic",
        "label" => "crew",
        "unit" => "tokens",
        "window" => "weekly",
        "allowance" => "500"
      }
    })
    |> render_submit()

    view
    |> form("#usage-form", %{
      "account" => %{
        "provider" => "anthropic",
        "label" => "crew",
        "unit" => "",
        "window" => "",
        "used" => "42"
      }
    })
    |> render_submit()

    {:ok, accounts} = UsageAccount.list(FirstmatePort.Tenancy.opts(user))
    [row] = Enum.filter(accounts, &(&1.label == "crew"))

    assert row.used == 42.0
    assert row.allowance == 500.0
    assert row.unit == :tokens
    assert row.window == :weekly
  end

  test "anonymous visitors go to login", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/usage")
  end
end
