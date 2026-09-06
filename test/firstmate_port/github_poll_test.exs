defmodule FirstmatePort.Jobs.GitHubPollTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Jobs.GitHubPoll

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

  test "parse_orgs splits comma-separated orgs" do
    assert GitHubPoll.parse_orgs(nil) == []
    assert GitHubPoll.parse_orgs("") == []
    assert GitHubPoll.parse_orgs("carverauto") == ["carverauto"]
    assert GitHubPoll.parse_orgs("carverauto, mfreeman451 ,,") == ["carverauto", "mfreeman451"]
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
end
