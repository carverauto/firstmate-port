defmodule FirstmatePort.Queues do
  @moduledoc """
  Live look-in at crew work in flight: which task went to which worker, its
  agent id, the model and effort it runs at, token usage, and start/stop times.

  The API is the only JetStream client, so the flow is one-way. `fm-steer`
  POSTs a queue fact to the portal; the portal records it in
  `FirstmatePort.Queues.Tracker` and publishes it on `<tenant>.steer.queue`,
  which the existing `<tenant>_steer` stream already owns — no new stream and no
  `<tenant>.>` catch-all. `FirstmatePort.NATS.QueueListener` folds messages from
  that subject back into the tracker, which is how a second portal node sees
  work recorded on the first.

  Publishing the normalized entry rather than the raw request is what makes that
  round trip safe: the recording node merges its own message back onto an
  identical entry and broadcasts nothing.
  """

  alias FirstmatePort.NATS
  alias FirstmatePort.Queues.{Entry, Tracker}
  alias FirstmatePort.Tenancy

  @doc "The JetStream subject queue facts travel on, inside the tenant's steer stream."
  def subject(tenant), do: Tenancy.slug(tenant) <> ".steer.queue"

  @doc "True when a subject carries queue facts rather than other steer traffic."
  def subject?(subject) when is_binary(subject), do: String.ends_with?(subject, ".steer.queue")
  def subject?(_), do: false

  defdelegate list(tenant), to: Tracker
  defdelegate topic(tenant), to: Tracker

  @doc """
  Records a queue fact reported over HTTP and fans it out to the other nodes.
  A fanout that cannot reach NATS is not an error: the look-in on this node is
  already correct, and queue facts are ephemeral.
  """
  @spec record(String.t(), map()) :: {:ok, Entry.t()} | {:error, atom()}
  def record(tenant, params) do
    with {:ok, entry} <- Tracker.track(tenant, params) do
      _ = publish(tenant, entry)
      {:ok, entry}
    end
  end

  @doc "Folds a queue fact that arrived over JetStream in without republishing it."
  @spec absorb(String.t(), map()) :: {:ok, Entry.t()} | {:error, atom()}
  defdelegate absorb(tenant, params), to: Tracker, as: :track

  defp publish(tenant, entry) do
    NATS.Connection.publish(subject(tenant), Jason.encode!(Entry.to_report(entry)))
  end
end
