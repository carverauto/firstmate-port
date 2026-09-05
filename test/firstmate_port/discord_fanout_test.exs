defmodule FirstmatePort.Jobs.DiscordFanoutTest do
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Jobs.DiscordFanout
  alias FirstmatePort.Portal.NoMistakesRun
  alias FirstmatePort.Tenancy

  defmodule CapturePlug do
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(pid, {:posted, body})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(204, "")
    end
  end

  test "skips posting when application env webhook is nil even if OS env is set" do
    System.put_env("DISCORD_WEBHOOK_URL", "http://127.0.0.1:9/this-must-not-be-posted")
    assert Application.get_env(:firstmate_port, :discord_webhook_url) in [nil, ""]

    assert :ok =
             DiscordFanout.perform(%Oban.Job{
               args: %{"kind" => "roll", "id" => "not-a-real-id"}
             })
  after
    System.delete_env("DISCORD_WEBHOOK_URL")
  end

  test "generic no-mistakes copy never includes findings text" do
    previous = Application.get_env(:firstmate_port, :discord_webhook_url)
    actor = %{role: :agent, email: "agent@localhost", tenant_slug: "local"}
    marker = "UNIQUE-FINDINGS-SHOULD-NOT-LEAK-#{System.unique_integer([:positive])}"

    assert {:ok, run} =
             NoMistakesRun.record(
               %{
                 run_id: "fanout-test-#{System.unique_integer([:positive])}",
                 branch: "fm/fm-port",
                 findings: marker,
                 outcome: "failed"
               },
               Tenancy.opts(actor)
             )

    {:ok, server} = Bandit.start_link(plug: {CapturePlug, self()}, port: 0, startup_log: false)
    {:ok, %{port: port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}/hook"
    Application.put_env(:firstmate_port, :discord_webhook_url, url)

    assert :ok =
             DiscordFanout.perform(%Oban.Job{
               args: %{"kind" => "no_mistakes", "id" => run.id, "tenant" => "local"}
             })

    assert_receive {:posted, body}, 1_000
    refute body =~ marker
    assert body =~ "failed" or body =~ "no-mistakes"
  after
    Application.put_env(:firstmate_port, :discord_webhook_url, previous)
  end
end
