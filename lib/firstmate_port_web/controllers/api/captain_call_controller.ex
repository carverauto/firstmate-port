defmodule FirstmatePortWeb.Api.CaptainCallController do
  @moduledoc """
  `POST /api/captain/calls` - firstmate asking the captain a bounded question in
  Discord, and `GET` for what has come back.

  Posting to Discord happens on this request rather than behind a job, because
  the caller's next move depends on whether the captain can actually see the
  question: a 201 means the message is in the channel with a select on it, and a
  502 means it is not, with the reason on the returned call. Nothing is retried
  here - a queue of questions the captain never asked for is worse than one that
  failed where the crew could see it.

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

  def index(conn, params) do
    calls =
      case params["status"] do
        "open" -> CaptainCalls.open(conn.assigns.current_user)
        _ -> CaptainCalls.recent(conn.assigns.current_user)
      end

    case calls do
      {:ok, calls} -> json(conn, %{"data" => Enum.map(calls, &CaptainCalls.wire/1)})
      {:error, error} -> conn |> put_status(:bad_request) |> json(%{"error" => describe(error)})
    end
  end

  def show(conn, %{"id" => id}) do
    case CaptainCalls.get(conn.assigns.current_user, id) do
      {:ok, nil} -> not_found(conn)
      {:ok, call} -> json(conn, CaptainCalls.wire(call))
      _ -> not_found(conn)
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{"error" => "not found"})

  defp describe(error), do: Errors.describe(error, "the question could not be asked")
end
