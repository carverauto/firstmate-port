defmodule FirstmatePort.NATS.JetstreamConsumerTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.NATS.JetstreamConsumer

  test "owned streams do not overlap and are not a firstmate.> catch-all" do
    assert JetstreamConsumer.steer_stream() == "firstmate-steer"
    assert JetstreamConsumer.inbound_stream() == "captain-inbound"
    assert JetstreamConsumer.steer_subjects() == ["firstmate.steer.>"]
    assert JetstreamConsumer.inbound_subjects() == ["firstmate.discord.inbound"]
    refute "firstmate.>" in JetstreamConsumer.steer_subjects()
    refute "firstmate.>" in JetstreamConsumer.inbound_subjects()
    refute JetstreamConsumer.steer_subjects() == JetstreamConsumer.inbound_subjects()
  end
end
