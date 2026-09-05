defmodule FirstmatePort.LinksTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Links

  test "keeps the original https URL rather than reassembling it" do
    url = "https://github.com/mfreeman451/firstmate-port/pull/1"
    assert {:ok, ^url} = Links.https(url)
  end

  test "rejects assembled or non-https values" do
    assert {:error, :not_https} = Links.https("http://github.com/example/app/pull/1")
    assert {:error, :not_https} = Links.https("github.com/example/app/pull/1")
    assert {:error, :empty} = Links.https("")
  end

  test "PRs and issues require https; notes may omit" do
    url = "https://github.com/example/app/issues/12"
    assert {:ok, ^url} = Links.progress_url("issue", url)
    assert {:error, :empty} = Links.progress_url("pr", "")
    assert {:ok, ""} = Links.progress_url("note", "")
  end

  test "email domain is exact" do
    assert Links.allowed_email?("ada@example.com", "example.com")
    refute Links.allowed_email?("ada@example.com.evil.com", "example.com")
    refute Links.allowed_email?("not-an-email", "example.com")
  end
end
