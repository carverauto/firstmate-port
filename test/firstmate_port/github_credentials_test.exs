defmodule FirstmatePort.Jobs.GitHubCredentialsTest do
  @moduledoc """
  Where the GitHub poll gets its token: the slot the captain filled on the
  credentials page, and only then the environment.
  """
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Credentials
  alias FirstmatePort.Jobs.GitHubPoll
  alias FirstmatePort.Tenancy

  setup do
    slug = "gh#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

    {:ok, captain} =
      User.upsert_oidc(%{email: "#{slug}@example.com", name: slug, tenant_slug: slug},
        authorize?: false
      )

    {:ok, slug: slug, captain: captain}
  end

  test "falls back to the environment when the slot is empty", %{slug: slug} do
    System.put_env("GITHUB_TOKEN_TEST", "from-the-environment")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN_TEST") end)

    assert GitHubPoll.configured(slug, "token", "GITHUB_TOKEN_TEST") == "from-the-environment"
  end

  test "is blank when neither the slot nor the environment has one", %{slug: slug} do
    assert GitHubPoll.configured(slug, "token", "GITHUB_TOKEN_ABSENT") == ""
  end

  test "the stored PAT wins over the environment", %{slug: slug, captain: captain} do
    System.put_env("GITHUB_TOKEN_TEST", "from-the-environment")
    on_exit(fn -> System.delete_env("GITHUB_TOKEN_TEST") end)

    {:ok, _} =
      Credentials.put(
        %{provider: "github", key: "token", value: "ghp_from_the_portal", description: ""},
        Tenancy.opts(captain)
      )

    assert GitHubPoll.configured(slug, "token", "GITHUB_TOKEN_TEST") == "ghp_from_the_portal"
  end

  test "the organisation is configurable the same way", %{slug: slug, captain: captain} do
    {:ok, _} =
      Credentials.put(
        %{provider: "github", key: "org", value: "carverauto", description: ""},
        Tenancy.opts(captain)
      )

    assert GitHubPoll.configured(slug, "org", "GITHUB_ORG_ABSENT") == "carverauto"
  end

  test "one tenant's PAT is never read for another", %{captain: captain} do
    {:ok, _} =
      Credentials.put(
        %{provider: "github", key: "token", value: "ghp_only_mine", description: ""},
        Tenancy.opts(captain)
      )

    other = "gh#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.seed(%{slug: other, name: other}, authorize?: false)

    assert GitHubPoll.configured(other, "token", "GITHUB_TOKEN_ABSENT") == ""
  end

  test "the poll does nothing at all without a token", %{captain: captain} do
    assert GitHubPoll.run(captain) == :ok
  end

  test "scheduled polling uses each tenant's PAT and appends title changes", %{captain: captain} do
    other_slug = "poll#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.seed(%{slug: other_slug, name: other_slug}, authorize?: false)
    {:ok, other} =
      User.upsert_oidc(
        %{email: "#{other_slug}@localhost", name: "Other", tenant_slug: other_slug},
        authorize?: false
      )

    for user <- [captain, other],
        {key, value} <- [{"token", "test-#{user.tenant_slug}"}, {"org", user.tenant_slug}] do
      {:ok, _} =
        Credentials.put(%{provider: "github", key: key, value: value}, Tenancy.opts(user))
    end

    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)
    owner = self()

    stub = fn title ->
      Req.default_options(plug: fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        [_, slug] = Regex.run(~r/org:([^ +]+)/, conn.query_params["q"])
        send(owner, {:poll, slug, Plug.Conn.get_req_header(conn, "authorization")})
        items =
          if String.contains?(conn.query_params["q"], "is:pr") do
            [%{"html_url" => "https://github.com/#{slug}/app/pull/1", "title" => title}]
          else
            []
          end
        Req.Test.json(conn, %{items: items})
      end)
    end

    stub.("Initial PR")
    assert :ok = GitHubPoll.run(nil)
    for user <- [captain, other] do
      slug = user.tenant_slug
      expected = ["Bearer test-#{slug}"]
      assert_receive {:poll, ^slug, ^expected}
      assert {:ok, [%{title: "Initial PR"}]} = FirstmatePort.Portal.ProgressItem.list(Tenancy.opts(user))
    end

    stub.("Revised PR")
    assert :ok = GitHubPoll.run(nil)
    assert :ok = GitHubPoll.run(nil)
    for user <- [captain, other] do
      opts = Tenancy.opts(user)
      assert {:ok, [%{id: id, title: "Revised PR"}]} = FirstmatePort.Portal.ProgressItem.list(opts)
      assert {:ok, [%{item_id: ^id, title: "Revised PR"}]} = FirstmatePort.Portal.ProgressEvent.list(opts)
      assert %{rows: [["Initial PR"]]} = FirstmatePort.Repo.query!("SELECT title FROM progress_items WHERE id = $1", [id])
    end
  end

end
