defmodule FirstmatePort.NATS.QueueListenerTest do
  use ExUnit.Case, async: false

  alias FirstmatePort.NATS.QueueListener
  alias FirstmatePort.Queues
  alias FirstmatePort.Queues.Entry

  # NATS is disabled in test, so the listener sits in its retry loop with no
  # connection. That is exactly the state we want: messages can still be handed
  # to it directly, which exercises the JetStream ingress without a broker.
  setup do
    pid = start_supervised!(QueueListener)
    tenant = "ql-" <> Integer.to_string(System.unique_integer([:positive]))
    %{listener: pid, tenant: tenant}
  end

  defp deliver(pid, subject, body) do
    send(pid, {:msg, %{topic: subject, body: body, reply_to: nil}})
    # The listener is a GenServer, so a synchronous call flushes the message.
    :sys.get_state(pid)
  end

  test "a queue fact from JetStream lands in the look-in", ctx do
    payload =
      Jason.encode!(%{
        "task" => "from-the-wire",
        "worker" => "crew-8",
        "agent_id" => "agent-wire",
        "status" => "working",
        "model" => "claude-opus-5",
        "effort" => "high",
        "tokens_in" => 500,
        "tokens_out" => 250
      })

    deliver(ctx.listener, Queues.subject(ctx.tenant), payload)

    assert [%Entry{} = entry] = Queues.list(ctx.tenant)
    assert entry.task == "from-the-wire"
    assert entry.worker == "crew-8"
    assert entry.agent_id == "agent-wire"
    assert entry.status == :working
    assert Entry.tokens_total(entry) == 750
  end

  test "the raw subject is still broadcast for the traffic feed", ctx do
    Phoenix.PubSub.subscribe(FirstmatePort.PubSub, QueueListener.topic(ctx.tenant))
    deliver(ctx.listener, Queues.subject(ctx.tenant), ~s({"task":"peeked"}))

    assert_receive {:nats_event, %{subject: subject}}
    assert subject == Queues.subject(ctx.tenant)
  end

  test "other steer traffic never becomes a queue row", ctx do
    deliver(ctx.listener, ctx.tenant <> ".steer.inbox", ~s({"task":"inbox-item","body":"hi"}))
    assert Queues.list(ctx.tenant) == []
  end

  test "a malformed queue payload is dropped rather than crashing the listener", ctx do
    deliver(ctx.listener, Queues.subject(ctx.tenant), "not json")
    deliver(ctx.listener, Queues.subject(ctx.tenant), ~s({"worker":"no task here"}))

    assert Process.alive?(ctx.listener)
    assert Queues.list(ctx.tenant) == []
  end
end
