defmodule FirstmatePort.Portal.ProgressStatusTest do
  @moduledoc """
  Status mapping. A closed vocabulary in lifecycle order, and a GitHub mapping
  that only claims the three things GitHub can actually see.
  """

  use ExUnit.Case, async: true

  alias FirstmatePort.Portal.ProgressStatus

  test "the vocabulary is closed and in lifecycle order" do
    assert ProgressStatus.all() == [
             :draft,
             :in_progress,
             :ready_for_review,
             :ready_for_merge,
             :stalled,
             :merged,
             :complete
           ]
  end

  test "labels are the captain's words" do
    assert Enum.map(ProgressStatus.all(), &ProgressStatus.label/1) == [
             "draft",
             "in progress",
             "ready for review",
             "ready for merge",
             "stalled",
             "merged",
             "complete"
           ]
  end

  test "merged and complete are the terminal states" do
    assert ProgressStatus.terminal() == [:merged, :complete]
    assert ProgressStatus.terminal?(:merged)
    assert ProgressStatus.terminal?(:complete)
    refute ProgressStatus.terminal?(:ready_for_merge)
    refute ProgressStatus.terminal?(:stalled)
  end

  describe "from_github/2" do
    test "a merged pull request is merged" do
      item = %{"state" => "closed", "pull_request" => %{"merged_at" => "2026-09-01T00:00:00Z"}}
      assert ProgressStatus.from_github(:pr, item) == :merged
    end

    test "an open pull request is in progress" do
      item = %{"state" => "open", "pull_request" => %{"merged_at" => nil}}
      assert ProgressStatus.from_github(:pr, item) == :in_progress
    end

    test "an open issue is in progress" do
      assert ProgressStatus.from_github(:issue, %{"state" => "open"}) == :in_progress
    end

    test "a closed issue is complete" do
      assert ProgressStatus.from_github(:issue, %{"state" => "closed"}) == :complete
    end

    test "a closed unmerged pull request is complete, not merged" do
      item = %{"state" => "closed", "pull_request" => %{"merged_at" => nil}}
      assert ProgressStatus.from_github(:pr, item) == :complete
    end

    test "it only ever produces the three states GitHub can observe" do
      shapes = [
        %{"state" => "open"},
        %{"state" => "closed"},
        %{"state" => "closed", "pull_request" => %{"merged_at" => "2026-01-01T00:00:00Z"}},
        %{}
      ]

      produced =
        for kind <- [:pr, :issue], shape <- shapes, do: ProgressStatus.from_github(kind, shape)

      assert Enum.uniq(produced) |> Enum.sort() == [:complete, :in_progress, :merged]
    end

    test "the mapping never reads the author" do
      item = %{"state" => "open", "user" => %{"login" => "mfreeman451"}}
      assert ProgressStatus.from_github(:pr, item) == :in_progress
    end
  end

  describe "github_may_report?/2" do
    test "a merge or a close always wins" do
      for current <- ProgressStatus.all() ++ [nil], observed <- [:merged, :complete] do
        assert ProgressStatus.github_may_report?(observed, current),
               "#{observed} should be able to overwrite #{inspect(current)}"
      end
    end

    test "an observed in-progress never drags a crew judgement backwards" do
      for current <- [:draft, :in_progress, :ready_for_review, :ready_for_merge, :stalled] do
        refute ProgressStatus.github_may_report?(:in_progress, current),
               "in_progress should not overwrite #{current}"
      end
    end

    test "an observed in-progress does reopen something the log called finished" do
      assert ProgressStatus.github_may_report?(:in_progress, :merged)
      assert ProgressStatus.github_may_report?(:in_progress, :complete)
    end

    test "anything is reportable onto a row whose log has no status yet" do
      assert ProgressStatus.github_may_report?(:in_progress, nil)
      assert ProgressStatus.github_may_report?(:merged, nil)
    end

    test "the poll can never report a crew-only judgement" do
      for observed <- [:draft, :ready_for_review, :ready_for_merge, :stalled] do
        refute ProgressStatus.github_may_report?(observed, :in_progress)
      end
    end
  end

  describe "default_for_kind/1" do
    test "prs and issues start in progress" do
      assert ProgressStatus.default_for_kind(:pr) == :in_progress
      assert ProgressStatus.default_for_kind(:issue) == :in_progress
    end

    test "achievements and notes are already complete" do
      assert ProgressStatus.default_for_kind(:achievement) == :complete
      assert ProgressStatus.default_for_kind(:note) == :complete
    end
  end

  describe "parse/1" do
    test "accepts the hyphenated and spaced spellings the captain uses" do
      assert ProgressStatus.parse("in-progress") == {:ok, :in_progress}
      assert ProgressStatus.parse("In Progress") == {:ok, :in_progress}
      assert ProgressStatus.parse("ready for review") == {:ok, :ready_for_review}
      assert ProgressStatus.parse("ready-for-merge") == {:ok, :ready_for_merge}
      assert ProgressStatus.parse("stalled") == {:ok, :stalled}
      assert ProgressStatus.parse("draft") == {:ok, :draft}
      assert ProgressStatus.parse(:complete) == {:ok, :complete}
    end

    test "rejects anything outside the vocabulary" do
      assert ProgressStatus.parse("reviewing") == :error
      assert ProgressStatus.parse("closed") == :error
      assert ProgressStatus.parse("abandoned") == :error
      assert ProgressStatus.parse(nil) == :error
      assert ProgressStatus.parse(42) == :error
    end

    test "every public status round-trips through its own label" do
      for status <- ProgressStatus.all() do
        assert ProgressStatus.parse(ProgressStatus.label(status)) == {:ok, status}
      end
    end
  end
end
