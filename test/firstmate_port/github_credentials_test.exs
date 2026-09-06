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
end
