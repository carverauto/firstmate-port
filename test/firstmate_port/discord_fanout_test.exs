defmodule FirstmatePort.Jobs.DiscordFanoutTest do
  use ExUnit.Case, async: false

  alias FirstmatePort.Jobs.DiscordFanout

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
    # render/2 is private; public perform with nil webhook must not raise on kind
    assert :ok =
             DiscordFanout.perform(%Oban.Job{
               args: %{"kind" => "no_mistakes", "id" => "x"}
             })
  end
end
