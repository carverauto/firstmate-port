defmodule FirstmatePortWeb.Api.CaptainCallController do
  @moduledoc """
  `POST /api/captain/calls` - firstmate asking the captain a bounded question in
  Discord.

  Posting runs on the request so the caller receives the delivery result.
  Status codes and delivery-race semantics live in `docs/captain-calls.md`.

  The answer does not come back through this endpoint. It arrives on
  `POST /interactions` as a signed Discord interaction and is filed into the
  tenant's inbox on the call's `task`, so the crew reads it with
  `fm-steer inbox next --task <task>` like any other order. See
  `docs/captain-calls.md`.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.CaptainCalls
  # The same scrubbing credential writes get. A rejected question is the
  # caller's own JSON rather than a secret, but nothing is lost by not echoing
  # it, and this is already the one place that knows how to flatten Ash's
  # nesting into a sentence.
  alias FirstmatePort.Credentials.Errors

  def create(conn, params) do
    case CaptainCalls.ask(conn.assigns.current_user, params) do
      {:ok, call} ->
        conn |> put_status(:created) |> json(CaptainCalls.wire(call))

      {:error, {:undeliverable, call}} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{"error" => call.delivery_error, "call" => CaptainCalls.wire(call)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => describe(error)})
    end
  end

  defp describe(error), do: Errors.describe(error, "the question could not be asked")
end
