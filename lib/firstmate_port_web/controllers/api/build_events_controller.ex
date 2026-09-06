defmodule FirstmatePortWeb.Api.BuildEventsController do
  @moduledoc """
  Build and deployment ingest for `fm-steer build start|finish`.

  Ingest lives here rather than in `IngestController` because the log is
  append-only: alongside the raw events this exposes the run projection the
  dashboard reads, which the other Fleet log kinds have no equivalent of.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.BuildEvents
  alias FirstmatePort.Portal.BuildEvent
  alias FirstmatePort.Tenancy

  @default_run_limit 10
  @max_run_limit 200

  def create(conn, params) do
    actor = conn.assigns.current_user

    attrs = %{
      run_id: params["run_id"],
      kind: params["kind"],
      target: params["target"] || "",
      status: params["status"],
      agent_id: params["agent_id"],
      model: params["model"] || "",
      effort: params["effort"] || "",
      tokens: integer(params["tokens"]),
      started_at: params["started_at"],
      finished_at: params["finished_at"],
      image: params["image"] || "",
      image_tag: params["image_tag"] || "",
      cluster: params["cluster"] || "",
      namespace: params["namespace"] || "",
      outcome: params["outcome"] || ""
    }

    case BuildEvent.record(attrs, Tenancy.opts(actor)) do
      {:ok, event} ->
        json(conn, %{
          id: event.id,
          run_id: event.run_id,
          kind: event.kind,
          status: event.status,
          url: run_url(event.run_id)
        })

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
    end
  end

  def index(conn, params) do
    opts = Tenancy.opts(conn.assigns.current_user)

    result =
      case params["run_id"] do
        run_id when is_binary(run_id) and run_id != "" -> BuildEvent.for_run(run_id, opts)
        _ -> BuildEvent.list(opts)
      end

    case result do
      {:ok, events} -> json(conn, %{data: Enum.map(events, &event_json/1)})
      {:error, error} -> conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  def runs(conn, params) do
    opts =
      conn.assigns.current_user
      |> Tenancy.opts()
      |> Keyword.put(:limit, limit(params["limit"]))

    case BuildEvents.runs(opts) do
      {:ok, runs} -> json(conn, %{data: Enum.map(runs, &run_json/1)})
      {:error, error} -> conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  defp event_json(%BuildEvent{} = event) do
    %{
      id: event.id,
      run_id: event.run_id,
      kind: event.kind,
      target: event.target,
      status: event.status,
      agent_id: event.agent_id,
      model: event.model,
      effort: event.effort,
      tokens: event.tokens,
      started_at: event.started_at,
      finished_at: event.finished_at,
      image: event.image,
      image_tag: event.image_tag,
      cluster: event.cluster,
      namespace: event.namespace,
      outcome: event.outcome,
      recorded_at: event.inserted_at
    }
  end

  defp run_json(run), do: Map.put(run, :url, run_url(run.run_id))

  defp run_url(run_id) do
    public_url() <> "/?tab=devops#" <> URI.encode_www_form(to_string(run_id))
  end

  defp public_url do
    Application.get_env(:firstmate_port, :public_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  defp limit(nil), do: @default_run_limit

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> limit(parsed)
      :error -> @default_run_limit
    end
  end

  defp limit(value) when is_integer(value) and value > 0, do: min(value, @max_run_limit)
  defp limit(_value), do: @default_run_limit

  defp integer(nil), do: 0
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp integer(_value), do: 0
end
