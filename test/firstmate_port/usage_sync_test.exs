defmodule FirstmatePort.Usage.SyncTest do
  use FirstmatePort.DataCase, async: true

  alias FirstmatePort.Portal.{UsageAccount, UsageSnapshot}
  alias FirstmatePort.Usage.Sync

  defp actor do
    %{role: :agent, email: "sync-test@localhost", tenant_slug: "local"}
  end

  test "parse_openrouter_key reads limit and usage" do
    body = %{"data" => %{"label" => "x", "limit" => 100.0, "usage" => 12.5}}

    assert Sync.parse_openrouter_key(body) == {:ok, %{limit: 100.0, usage: 12.5}}
  end

  test "parse_openrouter_key tolerates a missing limit" do
    assert Sync.parse_openrouter_key(%{"data" => %{"usage" => 3.0}}) ==
             {:ok, %{limit: nil, usage: 3.0}}
  end

  test "parse_openrouter_key rejects junk" do
    assert Sync.parse_openrouter_key(%{"nope" => true}) == {:error, :unexpected_body}
  end

  test "sync without a key reports unconfigured, touching nothing" do
    {:ok, account} =
      UsageAccount.record(
        %{provider: "openrouter", label: "k1", allowance: 50.0, used: 5.0},
        FirstmatePort.Tenancy.opts(actor())
      )

    result = Sync.sync_account(account, FirstmatePort.Tenancy.opts(actor()))

    assert result.synced? == false
    assert result.note =~ "OPENROUTER_API_KEY"
  end

  test "sync applies provider readings and appends a snapshot" do
    {:ok, account} =
      UsageAccount.record(
        %{provider: "openrouter", label: "k2", allowance: 50.0, used: 5.0},
        FirstmatePort.Tenancy.opts(actor())
      )

    http = fn {_url, _headers} ->
      {:ok, %{"data" => %{"limit" => 200.0, "usage" => 40.0}}}
    end

    System.put_env("OPENROUTER_API_KEY", "test-key")

    try do
      result = Sync.sync_account(account, FirstmatePort.Tenancy.opts(actor()), http: http)

      assert result.synced? == true
      assert result.account.used == 40.0
      assert result.account.allowance == 200.0
      assert result.account.source == :openrouter

      {:ok, snaps} = UsageSnapshot.for_account(account.id, FirstmatePort.Tenancy.opts(actor()))
      assert Enum.any?(snaps, &(&1.used == 40.0))
    after
      System.delete_env("OPENROUTER_API_KEY")
    end
  end

  test "sync keeps a manual allowance when the provider reports no cap" do
    {:ok, account} =
      UsageAccount.record(
        %{provider: "openrouter", label: "k3", allowance: 50.0, used: 5.0},
        FirstmatePort.Tenancy.opts(actor())
      )

    http = fn {_url, _headers} -> {:ok, %{"data" => %{"limit" => nil, "usage" => 9.0}}} end

    System.put_env("OPENROUTER_API_KEY", "test-key")

    try do
      result = Sync.sync_account(account, FirstmatePort.Tenancy.opts(actor()), http: http)

      assert result.synced? == true
      assert result.account.used == 9.0
      assert result.account.allowance == 50.0
    after
      System.delete_env("OPENROUTER_API_KEY")
    end
  end

  test "a non-scalar provider reading is reported, not raised" do
    {:ok, account} =
      UsageAccount.record(
        %{provider: "openrouter", label: "k5", allowance: 50.0, used: 5.0},
        FirstmatePort.Tenancy.opts(actor())
      )

    http = fn {_url, _headers} ->
      {:ok, %{"data" => %{"limit" => %{"monthly" => 200}, "usage" => ["40.0"]}}}
    end

    System.put_env("OPENROUTER_API_KEY", "test-key")

    try do
      result = Sync.sync_account(account, FirstmatePort.Tenancy.opts(actor()), http: http)

      assert result.synced? == false
      assert result.account.used == 5.0
      assert result.account.allowance == 50.0
    after
      System.delete_env("OPENROUTER_API_KEY")
    end
  end

  test "sync reports provider failures instead of raising" do
    {:ok, account} =
      UsageAccount.record(
        %{provider: "openrouter", label: "k4"},
        FirstmatePort.Tenancy.opts(actor())
      )

    http = fn {_url, _headers} -> {:error, :timeout} end

    System.put_env("OPENROUTER_API_KEY", "test-key")

    try do
      result = Sync.sync_account(account, FirstmatePort.Tenancy.opts(actor()), http: http)

      assert result.synced? == false
      assert result.note =~ "failed"
    after
      System.delete_env("OPENROUTER_API_KEY")
    end
  end

  test "non-openrouter providers report manual-only" do
    {:ok, account} =
      UsageAccount.record(
        %{provider: "anthropic", label: "direct"},
        FirstmatePort.Tenancy.opts(actor())
      )

    result = Sync.sync_account(account, FirstmatePort.Tenancy.opts(actor()))

    assert result.synced? == false
    assert result.note =~ "manually"
  end
end
