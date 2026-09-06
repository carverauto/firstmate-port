defmodule FirstmatePort.Fleet.ProjectionTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Fleet.Projection
  alias FirstmatePort.Portal.{Diagram, GithubItem, NoMistakesRun, ProgressItem, Roll}

  @at ~U[2026-09-05 12:00:00.000000Z]

  test "a GitHub item becomes JSON plus the canonical text over it" do
    item = %GithubItem{
      id: "pr1",
      kind: :pr,
      html_url: "https://github.com/example/app/pull/7",
      title: "Rework the roll job",
      state: :open,
      check_status: :failure,
      buildbuddy_url: "",
      firewall_verdict: :none,
      github_updated_at: @at,
      updated_at: @at
    }

    assert %{
             source: :github_item,
             source_id: "pr1",
             title: "Rework the roll job",
             url: "https://github.com/example/app/pull/7",
             occurred_at: @at,
             document: %{"kind" => "pr", "state" => "open", "check_status" => "failure"},
             search_text: text
           } = Projection.from(item)

    # Sorted keys, one labelled line each, empty values dropped.
    assert text =~ "check_status: failure"
    assert text =~ "title: Rework the roll job"
    refute text =~ "buildbuddy_url"
    assert String.starts_with?(text, "check_status:")
  end

  test "a GitHub item with no upstream timestamp falls back to when we last wrote it" do
    item = %GithubItem{
      id: "pr2",
      kind: :issue,
      html_url: "https://github.com/example/app/issues/9",
      title: "Flaky roll",
      state: :open,
      check_status: :none,
      github_updated_at: nil,
      updated_at: @at
    }

    assert %{occurred_at: @at} = Projection.from(item)
  end

  test "no-mistakes logs are not projected" do
    run = %NoMistakesRun{
      id: "nm1",
      run_id: "run-1",
      branch: "fm/example",
      step: "review",
      findings: "a finding worth searching for",
      logs: "megabytes of pipeline output",
      updated_at: @at
    }

    projection = Projection.from(run)

    assert projection.document["findings"] == "a finding worth searching for"
    refute Map.has_key?(projection.document, "logs")
    refute projection.search_text =~ "megabytes"
  end

  test "diagram payloads are never read, let alone projected" do
    diagram = %Diagram{
      id: "d1",
      title: "Runtime modes",
      notes: "auth and jetstream",
      inserted_at: @at
    }

    assert %{document: document} = Projection.from(diagram)
    assert document == %{"title" => "Runtime modes", "notes" => "auth and jetstream"}

    refute :html in Projection.select(Diagram)
    refute :png in Projection.select(Diagram)
    refute :logs in Projection.select(NoMistakesRun)
  end

  test "null bytes are stripped, because Postgres rejects them" do
    item = %ProgressItem{
      id: "p1",
      kind: :note,
      title: "before\x00after",
      url: "",
      body: "",
      updated_at: @at
    }

    assert %{title: "beforeafter", document: %{"title" => "beforeafter"}, search_text: text} =
             Projection.from(item)

    refute text =~ "\x00"
  end

  test "one runaway value cannot fill the index" do
    item = %ProgressItem{
      id: "p2",
      kind: :note,
      title: "Long",
      url: "",
      body: String.duplicate("x", 10_000),
      updated_at: @at
    }

    projection = Projection.from(item)

    assert String.length(projection.document["body"]) == 2_000
    assert String.length(projection.search_text) <= 8_000
  end

  test "the hash follows the content and nothing else" do
    roll = %Roll{
      id: "r1",
      cluster: "farm01",
      namespace: "serviceradar",
      status: :success,
      image_tag: "sha-deadbeef",
      rebuilt: ["web-ng"],
      copied: [],
      helm_revision: "",
      pr_url: "",
      issue_url: "",
      outcome: "rolled",
      inserted_at: @at
    }

    assert Projection.from(roll).content_hash ==
             Projection.from(%{roll | inserted_at: ~U[2020-01-01 00:00:00.000000Z]}).content_hash

    refute Projection.from(roll).content_hash ==
             Projection.from(%{roll | outcome: "rolled back"}).content_hash
  end

  test "list values survive into the JSON and the text" do
    roll = %Roll{
      id: "r2",
      cluster: "farm01",
      namespace: "serviceradar",
      status: :failure,
      image_tag: "sha-1",
      rebuilt: ["web-ng", "core"],
      copied: [],
      helm_revision: "",
      pr_url: "",
      issue_url: "",
      outcome: "",
      inserted_at: @at
    }

    assert %{document: %{"rebuilt" => ["web-ng", "core"]}, search_text: text} =
             Projection.from(roll)

    assert text =~ "rebuilt: web-ng core"
  end
end
