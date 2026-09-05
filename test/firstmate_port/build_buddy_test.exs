defmodule FirstmatePort.BuildBuddyTest do
  use ExUnit.Case, async: false

  alias FirstmatePort.BuildBuddy

  @host "https://bb.example.com"
  @key "org-key-for-tests"

  setup do
    original = Application.get_env(:firstmate_port, :build_tracking, [])

    Application.put_env(:firstmate_port, :build_tracking,
      kubernetes_enabled: false,
      docker_enabled: false,
      buildbuddy_host: @host,
      buildbuddy_api_key: @key
    )

    on_exit(fn -> Application.put_env(:firstmate_port, :build_tracking, original) end)
    :ok
  end

  test "configured? follows the key" do
    assert BuildBuddy.configured?()

    Application.put_env(:firstmate_port, :build_tracking, buildbuddy_api_key: nil)
    refute BuildBuddy.configured?()
  end

  test "invocation_url uses the configured host by default" do
    assert BuildBuddy.invocation_url("abc-123") == @host <> "/invocation/abc-123"
  end

  test "invocation_url accepts an explicit host and is nil without one" do
    assert BuildBuddy.invocation_url("abc", "https://other.example/") ==
             "https://other.example/invocation/abc"

    Application.put_env(:firstmate_port, :build_tracking, buildbuddy_api_key: @key)
    assert BuildBuddy.invocation_url("abc") == nil
    assert BuildBuddy.invocation_url("") == nil
    assert BuildBuddy.invocation_url(nil) == nil
  end

  test "parse_invocation_url splits host and id" do
    assert BuildBuddy.parse_invocation_url(@host <> "/invocation/abc-123") ==
             {:ok, %{host: @host, invocation_id: "abc-123"}}

    assert :error = BuildBuddy.parse_invocation_url("https://github.com/org/repo/pull/1")
    assert :error = BuildBuddy.parse_invocation_url(@host <> "/invocation/")
    assert :error = BuildBuddy.parse_invocation_url("not a url")
    assert :error = BuildBuddy.parse_invocation_url(nil)
  end

  test "get_invocation refuses without a key or host" do
    Application.put_env(:firstmate_port, :build_tracking, buildbuddy_api_key: nil)
    assert {:error, :unconfigured} = BuildBuddy.get_invocation("abc")

    Application.put_env(:firstmate_port, :build_tracking,
      buildbuddy_api_key: @key,
      buildbuddy_host: nil
    )

    assert {:error, :no_host} = BuildBuddy.get_invocation("abc")
  end

  test "get_invocation posts to GetInvocation with the api key header" do
    test_pid = self()

    Req.Test.stub(BuildBuddyGetStub, fn conn ->
      send(test_pid, {:path, conn.request_path})
      send(test_pid, {:key, Plug.Conn.get_req_header(conn, "x-buildbuddy-api-key")})

      Req.Test.json(conn, %{
        "invocation" => [
          %{
            "invocationId" => "abc-123",
            "invocationStatus" => "SUCCESS",
            "commitSha" => "deadbeef",
            "branchName" => "main",
            "repoUrl" => "https://github.com/example/app"
          }
        ]
      })
    end)

    assert {:ok, inv} =
             BuildBuddy.get_invocation("abc-123",
               req_options: [plug: {Req.Test, BuildBuddyGetStub}]
             )

    assert inv.invocation_id == "abc-123"
    assert inv.status == "SUCCESS"
    assert inv.commit_sha == "deadbeef"
    assert inv.branch == "main"
    assert inv.repo_url == "https://github.com/example/app"
    assert inv.url == @host <> "/invocation/abc-123"

    assert_received {:path, "/rpc/BuildBuddyService/GetInvocation"}
    assert_received {:key, [@key]}
  end

  test "get_invocation surfaces http failures without the key" do
    Req.Test.stub(BuildBuddyFailStub, fn conn ->
      Req.Test.json(conn |> Plug.Conn.put_status(401), %{"error" => "bad key"})
    end)

    assert {:error, {:http, 401, message}} =
             BuildBuddy.get_invocation("abc", req_options: [plug: {Req.Test, BuildBuddyFailStub}])

    assert is_binary(message)
    refute message =~ @key
  end

  test "recent_invocations returns newest-first normalized rows" do
    Req.Test.stub(BuildBuddySearchStub, fn conn ->
      assert conn.request_path == "/rpc/BuildBuddyService/SearchInvocation"

      Req.Test.json(conn, %{
        "invocation" => [%{"invocationId" => "one"}, %{"invocationId" => "two"}]
      })
    end)

    assert {:ok, [first, second]} =
             BuildBuddy.recent_invocations(
               count: 2,
               req_options: [plug: {Req.Test, BuildBuddySearchStub}]
             )

    assert first.invocation_id == "one"
    assert second.invocation_id == "two"
  end
end
