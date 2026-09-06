defmodule FirstmatePortWeb.InboxLiveTest do
  @moduledoc """
  The portal side of the message bus: what the captain sees of the traffic
  between firstmate, the second mate, and the crew.
  """
  use FirstmatePortWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Inbox

  setup %{conn: conn} do
    captain = human("local")
    {:ok, conn: sign_in(conn, captain), captain: captain, outsider: human("other")}
  end

  test "shows what fm-steer filed, including who sent it", %{conn: conn, captain: captain} do
    {:ok, _} = Inbox.put(captain, %{"body" => "second mate: PR is green"})

    {:ok, _view, html} = live(conn, ~p"/inbox")

    assert html =~ "second mate: PR is green"
    assert html =~ to_string(captain.email)
    assert html =~ "firstmate"
  end

  test "a message filed while the page is open arrives without a reload", %{
    conn: conn,
    captain: captain
  } do
    {:ok, view, html} = live(conn, ~p"/inbox")
    refute html =~ "arrived over pubsub"

    {:ok, _} = Inbox.put(captain, %{"task" => "fm-port", "body" => "arrived over pubsub"})

    assert render(view) =~ "arrived over pubsub"
  end

  test "the captain sends an order the crew can then take", %{conn: conn, captain: captain} do
    {:ok, view, _html} = live(conn, ~p"/inbox")

    html =
      view
      |> form("#order-form-0", %{"task" => "fm-port", "body" => "rebase onto main"})
      |> render_submit()

    assert html =~ "rebase onto main"

    {:ok, taken} = Inbox.next(captain, "fm-port")
    assert taken["body"] == "rebase onto main"
    assert taken["sender"] == to_string(captain.email)
  end

  test "acking from the portal clears it from the CLI's open list", %{
    conn: conn,
    captain: captain
  } do
    {:ok, message} = Inbox.put(captain, %{"body" => "ack me"})

    {:ok, view, _html} = live(conn, ~p"/inbox")
    view |> element("button[phx-value-ack='#{message["ack"]}']") |> render_click()

    assert {:ok, []} = Inbox.list(captain)
  end

  test "another tenant's traffic is not on the page", %{conn: conn, outsider: outsider} do
    {:ok, _} = Inbox.put(outsider, %{"body" => "not yours"})

    {:ok, _view, html} = live(conn, ~p"/inbox")
    refute html =~ "not yours"
  end

  test "a delayed pending broadcast cannot undo an acknowledgment", %{
    conn: conn,
    captain: captain
  } do
    {:ok, pending} = Inbox.put(captain, %{body: "late notification"})
    {:ok, view, _} = live(conn, ~p"/inbox")
    {:ok, _} = Inbox.ack(captain, pending["ack"])
    send(view.pid, {:inbox_message, pending})

    assert render(view) =~ "0 waiting"
    refute has_element?(view, "button[phx-value-ack='#{pending["ack"]}']")
  end

  test "task history and backlog survive more than 200 newer messages", %{
    conn: conn,
    captain: captain
  } do
    {:ok, _} = Inbox.put(captain, %{task: "fm-port", body: "older waiting order"})

    for n <- 1..200 do
      {:ok, message} = Inbox.put(captain, %{task: "elsewhere", body: "completed #{n}"})
      {:ok, _} = Inbox.ack(captain, message["ack"])
    end

    {:ok, view, html} = live(conn, ~p"/inbox")
    assert html =~ "1 waiting"
    refute html =~ "older waiting order"
    render_patch(view, ~p"/inbox?task=fm-port")
    assert render(view) =~ "older waiting order"
    assert render(view) =~ "1 waiting"
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
end
