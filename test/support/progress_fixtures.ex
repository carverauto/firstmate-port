defmodule FirstmatePort.ProgressFixtures do
  @moduledoc """
  Shared setup for the progress tests: a tenant, an agent that may append to the
  fleet log, and helpers for seeding items and events.

  Seeded items are spaced by a couple of milliseconds so "newest first" is
  deterministic rather than a coin flip on identical timestamps.
  """

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem}
  alias FirstmatePort.Tenancy

  @doc "A tenant plus an agent actor, and the Ash opts that carry them."
  def agent_context(prefix) do
    {:ok, _} = Tenant.seed(%{slug: "local", name: "local"}, authorize?: false)

    {:ok, agent} =
      User.bootstrap_agent(
        %{
          email: "#{prefix}@localhost",
          name: prefix,
          tenant_slug: "local",
          hashed_api_key: User.hash_token(api_key(prefix))
        },
        authorize?: false
      )

    %{agent: agent, opts: Tenancy.opts(agent), api_key: api_key(prefix)}
  end

  @doc "The bearer token `agent_context/1` provisions for a given prefix."
  def api_key(prefix), do: "fmh_test_#{prefix}"

  @doc "A signed-in human in the same tenant, for LiveView tests."
  def human(prefix) do
    {:ok, user} =
      User.upsert_oidc(
        %{
          email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
          name: "Human #{prefix}",
          tenant_slug: "local"
        },
        authorize?: false
      )

    user
  end

  @doc """
  Seeds `n` progress items, oldest first in the returned list.

  Titles are zero-padded so a substring assertion on "note-05" cannot
  accidentally match "note-15".
  """
  def seed_items(opts, n, kind \\ :note) do
    for i <- 1..n do
      item = seed_item(opts, kind: kind, title: "note-#{pad(i)}")
      Process.sleep(2)
      item
    end
  end

  @doc "The default crew member `seed_item/2` assigns work to."
  def default_worker, do: "crew-fixture"

  @doc "The zero-padded title `seed_items/3` gives its nth item."
  def title(i), do: "note-#{pad(i)}"

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 2, "0")

  @doc """
  Seeds one progress item.

  PRs and issues must carry a real https URL, so one is generated when the
  caller does not supply it; achievements and notes stay URL-less.

  `:record` requires a worker, so every seeded row opens with an `:assignment`
  event, exactly as a real one does. Pass `worker:` to name someone else.
  """
  def seed_item(opts, attrs) do
    attrs = Map.new(attrs)
    kind = Map.get(attrs, :kind, :note)

    {:ok, item} =
      ProgressItem.record(
        %{
          kind: kind,
          title: Map.fetch!(attrs, :title),
          url: Map.get(attrs, :url) || default_url(kind),
          body: Map.get(attrs, :body, ""),
          worker: Map.get(attrs, :worker, default_worker())
        },
        opts
      )

    item
  end

  @doc """
  Inserts a row the way the GitHub poll used to: no worker, no events at all.

  Rows like this exist in the wild from before Progress required crew
  attribution, so the projection and the UI still have to render them honestly.
  `Ash.Seed` is the only way to make one now — `:record` will not.
  """
  def seed_legacy_item(opts, attrs) do
    attrs = Map.new(attrs)
    kind = Map.get(attrs, :kind, :note)

    Ash.Seed.seed!(ProgressItem, %{
      id: FirstmatePort.Changes.AssignPublicId.generate(),
      kind: kind,
      title: Map.fetch!(attrs, :title),
      url: Map.get(attrs, :url) || default_url(kind),
      body: "",
      tenant_slug: Keyword.fetch!(opts, :tenant)
    })
  end

  defp default_url(kind) when kind in [:pr, :issue] do
    "https://github.com/carverauto/firstmate-port/#{kind}/#{System.unique_integer([:positive])}"
  end

  defp default_url(_kind), do: ""

  @doc "Appends one event to an item's log."
  def append(item, attrs, opts) do
    {:ok, event} = ProgressEvent.append(Map.put(Map.new(attrs), :item_id, item.id), opts)
    event
  end
end
