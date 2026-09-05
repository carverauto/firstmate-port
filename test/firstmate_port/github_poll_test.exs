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

  test "progress is unchanged across identical polls" do
    existing = %{kind: :pr, title: "same"}
    refute GitHubPoll.progress_changed?(existing, :pr, "same")
    assert GitHubPoll.progress_changed?(existing, :pr, "new title")
    assert GitHubPoll.progress_changed?(existing, :issue, "same")
  end
end
