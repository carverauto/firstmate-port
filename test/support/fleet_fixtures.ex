defmodule FirstmatePort.FleetFixtures do
  @moduledoc """
  Tenants, actors, and fleet-log records for the fleet-search tests.

  Every builder takes a tenant slug and returns the record, so a test can say
  what it needs in one line and keep the interesting part visible.
  """

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Portal.{Diagram, GithubItem, NoMistakesRun, ProgressItem, Roll}
  alias FirstmatePort.Tenancy

  def tenant(slug) do
    {:ok, tenant} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)
    tenant
  end

  def human(slug) do
    {:ok, user} =
      User.upsert_oidc(
        %{email: email("human"), name: "human", tenant_slug: slug},
        authorize?: false
      )

    user
  end

  def agent(slug) do
    {:ok, user} =
      User.bootstrap_agent(
        %{
          email: email("agent"),
          name: "agent",
          hashed_api_key: User.hash_token(unique("token")),
          tenant_slug: slug
        },
        authorize?: false
      )

    user
  end

  @doc "An agent user plus its bearer token, for API tests."
  def agent_with_token(slug) do
    token = unique("fmh_test")

    {:ok, user} =
      User.bootstrap_agent(
        %{
          email: email("agent"),
          name: "agent",
          hashed_api_key: User.hash_token(token),
          tenant_slug: slug
        },
        authorize?: false
      )

    {user, token}
  end

  def github_item(actor, attrs \\ %{}) do
    {:ok, item} =
      GithubItem.upsert(
        Map.merge(
          %{
            kind: :pr,
            html_url: "https://github.com/example/app/pull/#{System.unique_integer([:positive])}",
            title: "Rework the roll job",
            state: :open,
            check_status: :success
          },
          attrs
        ),
        opts(actor)
      )

    item
  end

  def progress_item(actor, attrs \\ %{}) do
    {:ok, item} =
      ProgressItem.record(
        Map.merge(%{kind: :note, title: "A note", url: "", body: "", worker: "crew-fixture"}, attrs),
        opts(actor)
      )

    item
  end

  def roll(actor, attrs \\ %{}) do
    {:ok, roll} =
      Roll.record(
        Map.merge(
          %{
            cluster: "farm01",
            namespace: "serviceradar",
            status: :success,
            image_tag: "sha-deadbeef",
            outcome: "rolled"
          },
          attrs
        ),
        opts(actor)
      )

    roll
  end

  def no_mistakes_run(actor, attrs \\ %{}) do
    {:ok, run} =
      NoMistakesRun.record(
        Map.merge(
          %{
            run_id: unique("run"),
            branch: "fm/example",
            step: "review",
            findings: "one finding",
            logs: "a very long log the projection must leave out"
          },
          attrs
        ),
        opts(actor)
      )

    run
  end

  def diagram(actor, attrs \\ %{}) do
    {:ok, diagram} =
      Diagram.upload(
        Map.merge(
          %{title: "Runtime modes", notes: "auth and jetstream", html: "<h1>x</h1>"},
          attrs
        ),
        opts(actor)
      )

    diagram
  end

  @doc "A stub embedding client that returns one fixed vector per text."
  def stub_client(vectors) do
    fn _model, texts, _opts ->
      {:ok, Enum.map(texts, fn text -> Map.get(vectors, text, List.duplicate(0.0, 3)) end)}
    end
  end

  defp opts(actor), do: Tenancy.opts(actor)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp email(prefix), do: unique(prefix) <> "@example.com"
end
