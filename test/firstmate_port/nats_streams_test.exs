defmodule FirstmatePort.NATS.JetstreamConsumerTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.NATS.JetstreamConsumer
  alias FirstmatePort.Tenancy

  test "owned streams do not overlap and are not a tenant.> catch-all" do
    assert JetstreamConsumer.steer_stream("acme") == "acme.steer"
    assert JetstreamConsumer.inbound_stream("acme") == "acme.inbound"
    assert JetstreamConsumer.steer_subjects("acme") == ["acme.steer.>"]
    assert JetstreamConsumer.inbound_subjects("acme") == ["acme.discord.inbound"]
    refute "acme.>" in JetstreamConsumer.steer_subjects("acme")
    refute "acme.>" in JetstreamConsumer.inbound_subjects("acme")
    refute JetstreamConsumer.steer_subjects("acme") == JetstreamConsumer.inbound_subjects("acme")
    refute JetstreamConsumer.steer_stream("acme") == JetstreamConsumer.steer_stream("beta")
    assert Tenancy.steer_stream("local") == "local.steer"
  end
end
