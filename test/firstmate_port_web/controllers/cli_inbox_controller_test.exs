defmodule FirstmatePortWeb.CliInboxControllerTest do
  @moduledoc """
  The inbox as `fm-steer` sees it: one shared queue both mates write to and read
  from, over HTTP, with the tenant as the only wall.
  """
  use FirstmatePortWeb.ConnCase, async: true

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Inbox

  setup do
    {:ok, second_mate: human("local"), first_mate: human("local"), outsider: human("other")}
  end

  test "a bare put files under the firstmate task", %{conn: conn, second_mate: mate} do
    body =
      conn
      |> as(mate)
      |> post(~p"/api/cli/inbox/put", %{"body" => "PR is green"})
      |> json_response(200)

    assert body["task"] == Inbox.default_task()
    assert body["schema"] == "fm-task-inbox.v1"
    assert body["body"] == "PR is green"
    assert body["sender"] == to_string(mate.email)
    assert body["status"] == "pending"
  end

  test "the second mate puts, the first mate takes it and acks it", %{
    conn: conn,
    second_mate: second,
    first_mate: first
  } do
    put =
      conn
      |> as(second)
      |> post(~p"/api/cli/inbox/put", %{"body" => "ship it"})
      |> json_response(200)

    taken =
      conn
      |> as(first)
      |> post(~p"/api/cli/inbox/next", %{})
      |> json_response(200)

    assert taken["ack"] == put["ack"]
    assert taken["body"] == "ship it"
    assert taken["status"] == "delivered"
    assert taken["claimed_by"] == to_string(first.email)

    # Claimed, so a second reader polling at the same time gets nothing.
    assert conn |> as(first) |> post(~p"/api/cli/inbox/next", %{}) |> response(204)

    assert conn
           |> as(first)
           |> post(~p"/api/cli/inbox/ack", %{"ack" => taken["ack"]})
           |> json_response(200) == %{"ok" => true}

    assert conn |> as(first) |> get(~p"/api/cli/inbox") |> json_response(200) == %{"data" => []}
  end

  test "orders addressed to a crew lane do not answer a bare next for another lane", %{
    conn: conn,
    second_mate: mate
  } do
    conn |> as(mate) |> post(~p"/api/cli/inbox/put", %{"task" => "fm-port", "body" => "rebase"})

    assert conn
           |> as(mate)
           |> post(~p"/api/cli/inbox/next", %{"task" => "some-other-lane"})
           |> response(204)

    taken =
      conn
      |> as(mate)
      |> post(~p"/api/cli/inbox/next", %{"task" => "fm-port"})
      |> json_response(200)

    assert taken["task"] == "fm-port"
  end

  test "another tenant never sees the message", %{
    conn: conn,
    second_mate: mate,
    outsider: outsider
  } do
    conn |> as(mate) |> post(~p"/api/cli/inbox/put", %{"body" => "tenant secret"})

    assert conn |> as(outsider) |> post(~p"/api/cli/inbox/next", %{}) |> response(204)

    assert conn |> as(outsider) |> get(~p"/api/cli/inbox") |> json_response(200) == %{
             "data" => []
           }
  end

  test "an empty body is refused, and no token at all is unauthorized", %{
    conn: conn,
    second_mate: mate
  } do
    assert conn
           |> as(mate)
           |> post(~p"/api/cli/inbox/put", %{"body" => "   "})
           |> json_response(422)

    assert conn
           |> put_req_header("accept", "application/json")
           |> post(~p"/api/cli/inbox/put", %{"body" => "no token"})
           |> json_response(401)
  end

  test "a message survives with its history: seq climbs and acked rows stay", %{
    conn: conn,
    second_mate: mate
  } do
    first =
      conn |> as(mate) |> post(~p"/api/cli/inbox/put", %{"body" => "one"}) |> json_response(200)

    second =
      conn |> as(mate) |> post(~p"/api/cli/inbox/put", %{"body" => "two"}) |> json_response(200)

    assert second["seq"] == first["seq"] + 1

    taken = conn |> as(mate) |> post(~p"/api/cli/inbox/next", %{}) |> json_response(200)
    conn |> as(mate) |> post(~p"/api/cli/inbox/ack", %{"ack" => taken["ack"]})

    {:ok, recent} = Inbox.recent(mate)
    assert Enum.map(recent, & &1["body"]) == ["two", "one"]
    assert Enum.find(recent, &(&1["body"] == "one"))["status"] == "acked"
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

  defp as(conn, %User{} = user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{"tenant" => user.tenant_slug})

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end
end
