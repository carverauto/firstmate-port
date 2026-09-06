# Demo fleet-log data for the progress surfaces.
#
#     mix run priv/repo/demo_progress.exs
#
# Deliberately NOT part of `mix setup` / `mix ecto.setup`: it invents workers,
# models, and token counts, which must never appear in a real deployment. Run it
# by hand on a local stack when you want /progress to have something to draw.
#
# It is idempotent by title: rerunning it appends no duplicate events, because
# an item whose title is already recorded is skipped.

require Logger

alias FirstmatePort.Accounts.{Tenant, User}
alias FirstmatePort.Portal.{ProgressEvent, ProgressItem}
alias FirstmatePort.Tenancy

slug = Tenancy.default_slug()
{:ok, _} = Tenant.seed(%{slug: slug, name: slug}, authorize?: false)

{:ok, agent} =
  User.bootstrap_agent(
    %{
      email: "demo-progress@localhost",
      name: "demo progress seeder",
      tenant_slug: slug,
      hashed_api_key: User.hash_token("fmh_demo_progress_seed")
    },
    authorize?: false
  )

opts = Tenancy.opts(agent)
repo = "https://github.com/carverauto/firstmate-port"

now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -minutes, :minute) end

# {kind, title, url, worker, assigned_at, [events]} — the worker opens the row's
# log with an :assignment event at assigned_at; the rest of the events are the
# story. Backdating the opening event is what a real backfill does, so the demo
# timeline reads the way a live one would.
demo = [
  {:pr, "Paginate the fleet log and add a progress page", "#{repo}/pull/9001",
   "fm-port-progress-page", ago.(600),
   [
     %{type: :status, status: :in_progress, occurred_at: ago.(600), detail: "github poll"},
     %{
       type: :contribution,
       worker: "fm-port-progress-page",
       role: :implement,
       runtime: "claude-code",
       model: "claude-opus-5",
       effort: "xhigh",
       duration_ms: 5_400_000,
       tokens: 412_000,
       interrupted: false,
       occurred_at: ago.(120)
     },
     %{
       type: :contribution,
       worker: "no-mistakes-review",
       role: :review,
       runtime: "no-mistakes",
       model: "claude-sonnet-5",
       effort: "high",
       duration_ms: 480_000,
       tokens: 61_000,
       occurred_at: ago.(80)
     },
     %{type: :status, status: :merged, occurred_at: ago.(30), detail: "github poll"}
   ]},
  {:pr, "Split fm-steer into cmd and internal packages", "#{repo}/pull/9002",
   "fm-steer-pkg-split", ago.(2880),
   [
     %{type: :status, status: :in_progress, occurred_at: ago.(2_880), detail: "github poll"},
     %{
       type: :contribution,
       worker: "fm-steer-pkg-split",
       role: :implement,
       runtime: "claude-code",
       model: "claude-opus-5",
       effort: "high",
       duration_ms: 2_700_000,
       tokens: 188_000,
       interrupted: true,
       occurred_at: ago.(2_600)
     },
     %{
       type: :interruption,
       interrupted: true,
       occurred_at: ago.(2_640),
       detail: "captain interrupted for a scope change"
     },
     %{
       type: :assignment,
       worker: "fm-steer-pkg-split-2",
       occurred_at: ago.(2_500),
       detail: "relaunched after the interrupt"
     },
     %{
       type: :contribution,
       worker: "fm-steer-pkg-split-2",
       role: :implement,
       runtime: "claude-code",
       model: "claude-opus-5",
       effort: "xhigh",
       duration_ms: 3_900_000,
       tokens: 240_000,
       interrupted: false,
       occurred_at: ago.(2_100)
     },
     %{
       type: :status,
       status: :ready_for_merge,
       occurred_at: ago.(2_050),
       detail: "review passed"
     },
     %{type: :status, status: :merged, occurred_at: ago.(2_000), detail: "github poll"}
   ]},
  {:issue, "taskrouter: collect stats on AI models", "#{repo}/issues/9003", "fm-taskrouter-stats",
   ago.(4_320),
   [
     %{type: :status, status: :in_progress, occurred_at: ago.(4_320), detail: "github poll"},
     %{
       type: :status,
       status: :stalled,
       occurred_at: ago.(1_200),
       detail: "waiting on a decision"
     },
     %{
       type: :contribution,
       worker: "fm-taskrouter-stats",
       role: :implement,
       runtime: "claude-code",
       model: "claude-sonnet-5",
       effort: "medium",
       duration_ms: 720_000,
       tokens: 54_000,
       interrupted: false,
       occurred_at: ago.(4_000)
     }
   ]},
  {:pr, "Restore scheduled ingestion for the fleet log", "#{repo}/pull/9004", "fm-port-fleet-log",
   ago.(300),
   [
     %{type: :status, status: :draft, occurred_at: ago.(300), detail: "opened as a draft"},
     %{type: :status, status: :in_progress, occurred_at: ago.(240), detail: "github poll"},
     %{
       type: :status,
       status: :ready_for_review,
       occurred_at: ago.(150),
       detail: "pushed for review"
     },
     %{
       type: :contribution,
       worker: "fm-port-fleet-log",
       role: :implement,
       runtime: "claude-code",
       model: "claude-opus-5",
       effort: "high",
       duration_ms: 180_000,
       tokens: 31_000,
       interrupted: false,
       occurred_at: ago.(200)
     }
   ]},
  {:issue, "Bootstrap password must survive a restart", "#{repo}/issues/9005",
   "fm-port-auth-runtime", ago.(10300),
   [
     %{type: :status, status: :complete, occurred_at: ago.(10_080), detail: "github poll"},
     %{
       type: :contribution,
       worker: "fm-port-auth-runtime",
       role: :implement,
       runtime: "claude-code",
       model: "claude-opus-5",
       effort: "high",
       duration_ms: 14_400_000,
       tokens: 520_000,
       interrupted: false,
       occurred_at: ago.(10_300)
     },
     %{
       type: :contribution,
       worker: "no-mistakes-review",
       role: :review,
       runtime: "no-mistakes",
       model: "claude-sonnet-5",
       effort: "medium",
       duration_ms: 240_000,
       tokens: 18_000,
       occurred_at: ago.(10_150)
     }
   ]},
  # Deliberately bare: the page must stay honest about a row nobody has
  # reported anything for.
  {:achievement, "Fleet log survived its first hundred rows", "", "fm-port-fleet-log", ago.(90),
   []},
  {:note, "Charts fall back to 'no telemetry yet' when nothing reported", "",
   "fm-port-progress-page", ago.(45), []}
]

{:ok, existing_items} = ProgressItem.list_for_stats(opts)
existing_titles = MapSet.new(existing_items, & &1.title)

created =
  Enum.reduce(demo, 0, fn entry, count ->
    {kind, title, url, worker, assigned_at, events} = entry

    if MapSet.member?(existing_titles, title) do
      Logger.info("demo progress: #{title} already present, skipping")
      count
    else
      {:ok, item} =
        ProgressItem.record(
          %{
            kind: kind,
            title: title,
            url: url,
            body: "",
            worker: worker,
            assigned_at: assigned_at
          },
          opts
        )

      for event <- events do
        {:ok, _} = ProgressEvent.append(Map.put(event, :item_id, item.id), opts)
      end

      count + 1
    end
  end)

Logger.info("demo progress: #{created} item(s) recorded in tenant #{slug}")
