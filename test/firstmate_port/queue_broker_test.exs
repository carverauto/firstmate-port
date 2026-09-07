defmodule FirstmatePort.QueueBrokerTest do
  use ExUnit.Case, async: false

  alias FirstmatePort.NATS.{Connection, JetstreamConsumer}
  alias FirstmatePort.Queues
  alias Gnat.Jetstream.API.Stream

  @moduletag :tmp_dir
  @moduletag skip: System.get_env("NATS_SERVER_TESTS") != "1"

  setup %{tmp_dir: tmp_dir} = context do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    executable = System.find_executable("nats-server") || raise "nats-server is required"

    jetstream = if Map.get(context, :jetstream, true), do: ["-js"], else: []

    broker =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :stderr_to_stdout,
        args: jetstream ++ ["-a", "127.0.0.1", "-p", Integer.to_string(port), "-sd", tmp_dir]
      ])

    {:os_pid, broker_pid} = Port.info(broker, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", Integer.to_string(broker_pid)])
    end)

    await_ready(broker)

    start_supervised!(%{
      id: Gnat,
      start:
        {Gnat, :start_link,
         [%{host: "127.0.0.1", port: port}, [name: Connection.connection_name()]]}
    })

    unless Process.whereis(FirstmatePort.PubSub) do
      start_supervised!({Phoenix.PubSub, name: FirstmatePort.PubSub})
    end

    unless Process.whereis(Queues.Tracker), do: start_supervised!(Queues.Tracker)
    %{conn: Process.whereis(Connection.connection_name())}
  end

  @tag timeout: 90_000
  test "owned streams provision and persist queue reports", %{conn: conn} do
    assert :ok = JetstreamConsumer.ensure_owned_streams(conn, "local")
    assert :ok = JetstreamConsumer.ensure_owned_streams(conn, "local")

    assert {:ok, %{config: %{subjects: ["local.steer.>"]}}} =
             Stream.info(conn, JetstreamConsumer.steer_stream("local"))

    assert {:ok, %{config: %{subjects: ["local.discord.inbound"]}}} =
             Stream.info(conn, JetstreamConsumer.inbound_stream("local"))

    assert {:ok, _} =
             JetstreamConsumer.ensure_durable(conn,
               stream_name: JetstreamConsumer.steer_stream("local"),
               consumer_name: "queue-regression"
             )

    assert {:ok, entry} =
             Queues.record("local", %{"task" => "broker-task", "status" => "working"})

    assert {:ok, %{subject: "local.steer.queue", data: body}} = stored_message(conn, 100)
    assert Jason.decode!(body) == Jason.decode!(Jason.encode!(Queues.Entry.to_report(entry)))
  end

  @tag timeout: 90_000, jetstream: false
  test "queue reports do not wait for unavailable stream provisioning", %{conn: conn} do
    # Capture and deliberately leave management requests unanswered, as with an
    # unavailable JetStream service. Core NATS publication remains available.
    {:ok, _} = Gnat.sub(conn, self(), "$JS.API.>")
    {:ok, _} = Gnat.sub(conn, self(), "local.steer.queue")
    {elapsed, result} = :timer.tc(fn -> Queues.record("local", %{"task" => "fast-task"}) end)
    assert {:ok, entry} = result
    assert elapsed < 1_000_000
    assert_receive {:msg, %{topic: "local.steer.queue", body: body}}, 1_000
    assert Jason.decode!(body)["task"] == entry.task
    refute_receive {:msg, %{topic: "$JS.API." <> _}}, 100
  end

  # Core NATS publish returns before JetStream has persisted the message.
  defp stored_message(conn, attempts) do
    result = Stream.get_message(conn, JetstreamConsumer.steer_stream("local"), %{seq: 1})

    case result do
      {:error, _} when attempts > 0 ->
        Process.sleep(10)
        stored_message(conn, attempts - 1)

      _ ->
        result
    end
  end

  defp await_ready(broker) do
    receive do
      {^broker, {:data, output}} ->
        if String.contains?(output, "Server is ready"), do: :ok, else: await_ready(broker)
    after
      5_000 -> flunk("NATS broker did not become ready")
    end
  end
end
