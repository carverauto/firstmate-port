defmodule FirstmatePort.Jobs.GitHubPollTest do
  use FirstmatePort.DataCase, async: true

  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Jobs.GitHubPoll
  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem, ProgressProjection}

  test "copies the BuildBuddy invocation URL from check-run details_url" do
    url = "https://buildbuddy.example.com/invocation/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    runs = [
      %{
        "details_url" => "https://github.com/example/app/actions",
        "html_url" => "https://github.com/x"
      },
      %{"details_url" => url, "status" => "completed", "conclusion" => "failure"}
    ]

    assert GitHubPoll.copied_buildbuddy_url(runs) == url
  end

  test "does not invent a BuildBuddy URL" do
    assert GitHubPoll.copied_buildbuddy_url([%{"details_url" => "https://github.com/a/b"}]) == ""
  end

  test "the default Req pool is supervised for outbound GitHub HTTP" do
    # The poll drives Req through its default Req.Finch pool, which the :req
    # OTP app supervises. A bare `eval` sidecar lacks it (unknown registry);
    # always trigger the poll on the running node via `rpc`.
    assert is_pid(Process.whereis(Req.Finch))
  end

  test "trim_credential strips secret-store trailing newlines" do
    assert GitHubPoll.trim_credential(nil) == nil
    assert GitHubPoll.trim_credential("") == ""
    assert GitHubPoll.trim_credential("ghp_example") == "ghp_example"
    assert GitHubPoll.trim_credential("ghp_example\n") == "ghp_example"
    assert GitHubPoll.trim_credential("  ghp_example\r\n") == "ghp_example"
  end

  test "progress is unchanged across identical polls" do
    existing = %{kind: :pr, title: "same"}
    refute GitHubPoll.progress_changed?(existing, :pr, "same")
    assert GitHubPoll.progress_changed?(existing, :pr, "new title")
    assert GitHubPoll.progress_changed?(existing, :issue, "same")
  end

  describe "Progress is crew work, not an org listing" do
    setup do
      {:ok, agent_context("github-poll")}
    end

    test "a PR nobody logged does not become a fleet-log row", ctx do
      raw = %{
        "html_url" => "https://github.com/carverauto/serviceradar/pull/4201",
        "title" => "chore(deps): bump some transitive thing",
        "state" => "open"
      }

      assert :ok = GitHubPoll.enrich_progress(raw, :pr, ctx.agent)
      assert {:ok, 0} = Ash.count(ProgressItem, ctx.opts)
    end

    test "a whole page of org noise creates nothing", ctx do
      for n <- 4197..4203 do
        raw = %{
          "html_url" => "https://github.com/carverauto/serviceradar/pull/#{n}",
          "title" => "chore(deps): bump #{n}",
          "state" => "open"
        }

        assert :ok = GitHubPoll.enrich_progress(raw, :pr, ctx.agent)
      end

      assert {:ok, 0} = Ash.count(ProgressItem, ctx.opts)
    end

    test "a row the crew already logged gets its status moved", ctx do
      url = "https://github.com/carverauto/firstmate-port/pull/42"
      item = seed_item(ctx.opts, kind: :pr, title: "crew work", url: url, worker: "crew-a")

      raw = %{
        "html_url" => url,
        "title" => "crew work",
        "state" => "closed",
        "pull_request" => %{"merged_at" => "2026-09-05T00:00:00Z"}
      }

      assert :ok = GitHubPoll.enrich_progress(raw, :pr, ctx.agent)

      assert {:ok, projection} = ProgressProjection.load_one(item, ctx.opts)
      assert projection.status == :merged
      assert projection.status_source == :log
      assert DateTime.compare(projection.completed_at, ~U[2026-09-05 00:00:00Z]) == :eq
    end

    test "a delayed open observation cannot outrank a later merge", ctx do
      url = "https://github.com/example/repo/pull/72"
      item = seed_item(ctx.opts, kind: :pr, title: "crew work", url: url)
      open_at = ~U[2026-09-05 12:00:00Z]
      merged_at = ~U[2026-09-05 12:01:00Z]

      stale = %{
        "html_url" => url,
        "title" => "crew work",
        "state" => "open",
        "updated_at" => DateTime.to_iso8601(open_at)
      }

      merged = %{
        "html_url" => url,
        "title" => "crew work",
        "state" => "closed",
        "pull_request" => %{"merged_at" => DateTime.to_iso8601(merged_at)}
      }

      assert :ok = GitHubPoll.enrich_progress(stale, :pr, ctx.agent)
      assert :ok = GitHubPoll.enrich_progress(merged, :pr, ctx.agent)
      assert {:ok, projection} = ProgressProjection.load_one(item, ctx.opts)
      assert projection.status == :merged
      assert DateTime.compare(projection.status_at, merged_at) == :eq

      assert :ok = GitHubPoll.enrich_progress(stale, :pr, ctx.agent)
      assert :ok = GitHubPoll.enrich_progress(merged, :pr, ctx.agent)
      assert {:ok, projection} = ProgressProjection.load_one(item, ctx.opts)
      assert projection.status == :merged
      assert {:ok, events} = ProgressEvent.list_for_item(item.id, ctx.opts)
      assert [opened, completed] = Enum.filter(events, &(&1.type == :status))
      assert DateTime.compare(opened.occurred_at, open_at) == :eq
      assert DateTime.compare(completed.occurred_at, merged_at) == :eq
    end

    test "an open observation without a valid source time cannot reopen completed work", ctx do
      url = "https://github.com/example/repo/issues/73"
      item = seed_item(ctx.opts, kind: :issue, title: "crew work", url: url)
      append(item, %{type: :status, status: :complete}, ctx.opts)

      for updated_at <- [nil, "invalid"] do
        raw = %{
          "html_url" => url,
          "title" => "crew work",
          "state" => "open",
          "updated_at" => updated_at
        }

        assert :ok = GitHubPoll.enrich_progress(raw, :issue, ctx.agent)
      end

      assert {:ok, projection} = ProgressProjection.load_one(item, ctx.opts)
      assert projection.status == :complete
      assert projection.event_count == 2
    end

    test "the poll refreshes a title but still does not create siblings", ctx do
      url = "https://github.com/carverauto/firstmate-port/pull/43"
      item = seed_item(ctx.opts, kind: :pr, title: "old title", url: url, worker: "crew-a")

      raw = %{"html_url" => url, "title" => "new title", "state" => "open"}
      assert :ok = GitHubPoll.enrich_progress(raw, :pr, ctx.agent)

      assert {:ok, 1} = Ash.count(ProgressItem, ctx.opts)
      assert {:ok, reloaded} = ProgressItem.get_by_id(item.id, ctx.opts)
      assert reloaded.title == "new title"
    end

    test "an observed open state never overwrites a crew judgement", ctx do
      url = "https://github.com/carverauto/firstmate-port/pull/44"
      item = seed_item(ctx.opts, kind: :pr, title: "under review", url: url, worker: "crew-a")

      append(item, %{type: :status, status: :ready_for_review}, ctx.opts)

      raw = %{
        "html_url" => url,
        "title" => "under review",
        "state" => "open",
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      assert :ok = GitHubPoll.enrich_progress(raw, :pr, ctx.agent)

      assert {:ok, projection} = ProgressProjection.load_one(item, ctx.opts)
      assert projection.status == :ready_for_review
    end

    test "a malformed search result is ignored", ctx do
      assert :ok = GitHubPoll.enrich_progress(%{"title" => "no url"}, :pr, ctx.agent)
      assert :ok = GitHubPoll.enrich_progress(%{}, :issue, ctx.agent)
      assert {:ok, 0} = Ash.count(ProgressItem, ctx.opts)
    end
  end
end
