defmodule FirstmatePortWeb.Api.IngestController do
  use FirstmatePortWeb, :controller

  alias FirstmatePort.BuildBuddy

  alias FirstmatePort.Portal.{
    BuildBuddyInvocation,
    Diagram,
    DockerBuild,
    NoMistakesRun,
    ProgressItem,
    ProgressEvent,
    ProgressLog,
    ProgressProjection,
    ProgressStatus,
    Roll
  }

  def create_diagram(conn, params) do
    actor = conn.assigns.current_user

    with {:ok, html} <- decode_bin("html_base64", params["html_base64"]),
         {:ok, png} <- decode_bin("png_base64", params["png_base64"]),
         {:ok, svg} <- decode_bin("svg_base64", params["svg_base64"]) do
      attrs = %{
        id: params["id"],
        title: params["title"] || "untitled",
        notes: params["notes"] || "",
        html: html,
        png: png,
        svg: svg
      }

      case Diagram.upload(attrs, FirstmatePort.Tenancy.opts(actor)) do
        {:ok, diagram} ->
          json(conn, %{
            id: diagram.id,
            url: public_url() <> "/d/" <> diagram.id,
            title: diagram.title
          })

        {:error, error} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
      end
    else
      {:error, field} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "#{field} must be base64-encoded"})
    end
  end

  @doc """
  Opens a fleet-log row for work a crew member is doing.

  `worker` is required. Progress tracks the PRs, issues, and tasks this fleet
  actually worked — a row that cannot name whose work it is does not belong in
  it, and that is what keeps an organisation's pull-request listing out. The
  worker is not stored on the row; it opens the row's log with an `:assignment`
  event. See `docs/progress.md`.
  """
  def create_progress(conn, params) do
    case params["worker"] do
      worker when is_binary(worker) and worker != "" ->
        record(conn, ProgressItem, :record, %{
          kind: params["kind"],
          title: params["title"],
          url: params["url"] || "",
          body: params["body"] || "",
          worker: worker
        })

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error:
            "worker is required: Progress tracks crew work, so a row must name who is doing it"
        })
    end
  end

  def create_roll(conn, params) do
    record(conn, Roll, :record, %{
      cluster: params["cluster"],
      namespace: params["namespace"],
      status: params["status"],
      image_tag: params["image_tag"],
      rebuilt: List.wrap(params["rebuilt"] || []),
      copied: List.wrap(params["copied"] || []),
      helm_revision: params["helm_revision"] || "",
      pr_url: params["pr_url"] || "",
      issue_url: params["issue_url"] || "",
      outcome: params["outcome"] || ""
    })
  end

  def create_docker_build(conn, params) do
    record(conn, DockerBuild, :record, %{
      repository: params["repository"],
      tag: params["tag"],
      status: params["status"],
      digest: params["digest"] || "",
      dockerfile: params["dockerfile"] || "",
      context: params["context"] || "",
      pr_url: params["pr_url"] || "",
      issue_url: params["issue_url"] || "",
      outcome: params["outcome"] || ""
    })
  end

  def create_buildbuddy_invocation(conn, params) do
    record(conn, BuildBuddyInvocation, :record, %{
      invocation_id: params["invocation_id"],
      host: BuildBuddy.host() || "",
      status: params["status"] || "",
      commit_sha: params["commit_sha"] || "",
      branch: params["branch"] || "",
      repo_url: params["repo_url"] || "",
      buildbuddy_url: params["buildbuddy_url"] || "",
      pr_url: params["pr_url"] || "",
      outcome: params["outcome"] || ""
    })
  end

  def create_no_mistakes(conn, params) do
    record(conn, NoMistakesRun, :record, %{
      run_id: params["run_id"],
      branch: params["branch"],
      step: params["step"] || "",
      findings: params["findings"] || "",
      pr_url: params["pr_url"] || "",
      outcome: params["outcome"] || "",
      intent: params["intent"] || "",
      logs: params["logs"] || "",
      public_summary: params["public_summary"] || "",
      firewall_verdict: params["firewall_verdict"] || "none"
    })
  end

  def list_diagrams(conn, _params), do: list(conn, Diagram)
  def list_rolls(conn, _params), do: list(conn, Roll)
  def list_docker_builds(conn, _params), do: list(conn, DockerBuild)
  def list_buildbuddy_invocations(conn, _params), do: list(conn, BuildBuddyInvocation)
  def list_no_mistakes(conn, _params), do: list(conn, NoMistakesRun)

  @doc """
  Lists progress items, newest first, each one already projected over its
  append-only event log.

  Contract: bounded — `limit` defaults to 50 and is capped at
  `ProgressItem.max_page_size/0`, `offset` defaults to 0. The response is
  `%{data: [...], meta: %{total: integer, limit: integer, offset: integer}}`.
  Walk the full archive with `limit`/`offset` (or the `/progress` portal page);
  this endpoint never dumps the whole table.
  """
  def list_progress(conn, params) do
    limit = clamp_int(params["limit"], 50, 1, ProgressItem.max_page_size())
    offset = clamp_int(params["offset"], 0, 0, nil)
    opts = FirstmatePort.Tenancy.opts(conn.assigns.current_user)

    with {:ok, rows} <- ProgressItem.list_paged(limit, offset, opts),
         {:ok, projections} <- ProgressProjection.load(rows, opts),
         {:ok, total} <- Ash.count(ProgressItem, opts) do
      json(conn, %{
        data: Enum.map(projections, &summarize_projection/1),
        meta: %{total: total, limit: limit, offset: offset}
      })
    else
      {:error, error} -> conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  @doc """
  One progress item with its full event log, oldest first.

  The log is what the details view renders; it is capped at
  `ProgressItem.max_page_size/0` events so a pathological row cannot become an
  unbounded response.
  """
  def show_progress(conn, %{"id" => id}) do
    opts = FirstmatePort.Tenancy.opts(conn.assigns.current_user)

    with {:ok, item} when not is_nil(item) <- ProgressItem.get_by_id(id, opts),
         {:ok, projection} <- ProgressProjection.load_one(item, opts) do
      events = Enum.take(projection.events, ProgressItem.max_page_size())

      json(
        conn,
        projection
        |> summarize_projection()
        |> Map.merge(%{
          body: item.body,
          events: Enum.map(events, &summarize_event/1),
          event_count: length(projection.events)
        })
      )
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such progress item"})
    end
  end

  @doc """
  Appends one event to a progress item's log. See `docs/progress.md` for the
  full contract.

  The item is named by `item_id` or by the `url` the producer already holds;
  this endpoint never creates the item, so a typo cannot fork a second
  fleet-log row. Nothing here updates or deletes: an event is only ever added.
  """
  def create_progress_event(conn, params) do
    opts = FirstmatePort.Tenancy.opts(conn.assigns.current_user)

    with {:ok, item} <- ProgressLog.find_item(params, opts),
         {:ok, attrs} <- event_attrs(item, params),
         {:ok, event} <- ProgressLog.append(attrs, opts) do
      json(conn, Map.put(summarize_event(event), :item_id, item.id))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "no progress item for that item_id or url"})

      {:error, {:bad_request, message}} ->
        conn |> put_status(:bad_request) |> json(%{error: message})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
    end
  end

  defp event_attrs(item, params) do
    with {:ok, type} <- parse_type(params["type"]),
         {:ok, status} <- parse_status(params["status"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, occurred_at} <- parse_occurred_at(params["occurred_at"]) do
      {:ok,
       %{
         item_id: item.id,
         type: type,
         status: status,
         role: role,
         worker: to_string(params["worker"] || ""),
         runtime: to_string(params["runtime"] || ""),
         model: to_string(params["model"] || ""),
         effort: to_string(params["effort"] || ""),
         detail: to_string(params["detail"] || ""),
         duration_ms: params["duration_ms"],
         tokens: params["tokens"],
         interrupted: params["interrupted"],
         occurred_at: occurred_at
       }}
    end
  end

  defp parse_type(raw) do
    case enum_member(raw, ProgressEvent.types()) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, {:bad_request, "type must be one of #{names(ProgressEvent.types())}"}}
    end
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(raw) do
    case ProgressStatus.parse(raw) do
      {:ok, status} -> {:ok, status}
      :error -> {:error, {:bad_request, "status must be one of #{names(ProgressStatus.all())}"}}
    end
  end

  defp parse_role(nil), do: {:ok, nil}
  defp parse_role(""), do: {:ok, nil}

  defp parse_role(raw) do
    case enum_member(raw, ProgressEvent.roles()) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, {:bad_request, "role must be one of #{names(ProgressEvent.roles())}"}}
    end
  end

  defp parse_occurred_at(nil), do: {:ok, nil}
  defp parse_occurred_at(""), do: {:ok, nil}

  defp parse_occurred_at(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _} -> {:ok, at}
      _ -> {:error, {:bad_request, "occurred_at must be an ISO 8601 timestamp"}}
    end
  end

  defp parse_occurred_at(_), do: {:error, {:bad_request, "occurred_at must be a string"}}

  defp enum_member(raw, allowed) when is_binary(raw) do
    normalized = raw |> String.trim() |> String.downcase() |> String.replace(["-", " "], "_")
    Enum.find_value(allowed, :error, &(to_string(&1) == normalized && {:ok, &1}))
  end

  defp enum_member(raw, allowed) when is_atom(raw) and not is_nil(raw) do
    if raw in allowed, do: {:ok, raw}, else: :error
  end

  defp enum_member(_raw, _allowed), do: :error

  defp names(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp clamp_int(nil, default, _min, _max), do: default

  defp clamp_int(raw, default, min, max) do
    case Integer.parse(to_string(raw)) do
      {n, _} ->
        n = max(n, min)
        if is_nil(max), do: n, else: min(n, max)

      :error ->
        default
    end
  end

  defp list(conn, resource) do
    case resource.list(FirstmatePort.Tenancy.opts(conn.assigns.current_user)) do
      {:ok, rows} -> json(conn, %{data: Enum.map(rows, &summarize/1)})
      {:error, error} -> conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  defp record(conn, resource, action, attrs) do
    case apply(resource, action, [attrs, FirstmatePort.Tenancy.opts(conn.assigns.current_user)]) do
      {:ok, item} ->
        json(conn, Map.merge(summarize(item), %{url: url_for(item)}))

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
    end
  end

  defp summarize(%Diagram{} = d), do: %{id: d.id, title: d.title, notes: d.notes}
  defp summarize(%ProgressItem{} = p), do: %{id: p.id, kind: p.kind, title: p.title, url: p.url}

  defp summarize(%Roll{} = r) do
    %{
      id: r.id,
      cluster: r.cluster,
      namespace: r.namespace,
      status: r.status,
      image_tag: r.image_tag,
      pr_url: r.pr_url
    }
  end

  defp summarize(%DockerBuild{} = b) do
    %{
      id: b.id,
      repository: b.repository,
      tag: b.tag,
      status: b.status,
      pr_url: b.pr_url
    }
  end

  defp summarize(%BuildBuddyInvocation{} = i) do
    %{
      id: i.id,
      invocation_id: i.invocation_id,
      status: i.status,
      buildbuddy_url: i.buildbuddy_url,
      pr_url: i.pr_url
    }
  end

  defp summarize(%NoMistakesRun{} = n) do
    %{
      id: n.id,
      run_id: n.run_id,
      branch: n.branch,
      step: n.step,
      pr_url: n.pr_url,
      outcome: n.outcome,
      firewall_verdict: n.firewall_verdict
    }
  end

  # Status, assignee, and totals are projected from the event log, never stored
  # on the item, so producers cannot drift them apart.
  defp summarize_projection(projection) do
    projection.item
    |> summarize()
    |> Map.merge(%{
      status: projection.status,
      status_source: projection.status_source,
      assignee: projection.assignee,
      workers: projection.workers,
      review_count: length(projection.reviewers),
      duration_ms: projection.duration_ms,
      tokens: projection.tokens,
      interrupted: projection.interrupted,
      inserted_at: projection.item.inserted_at
    })
  end

  defp summarize_event(%ProgressEvent{} = e) do
    %{
      id: e.id,
      item_id: e.item_id,
      type: e.type,
      status: e.status,
      worker: e.worker,
      role: e.role,
      runtime: e.runtime,
      model: e.model,
      effort: e.effort,
      duration_ms: e.duration_ms,
      tokens: e.tokens,
      interrupted: e.interrupted,
      detail: e.detail,
      occurred_at: e.occurred_at
    }
  end

  defp url_for(%Diagram{id: id}), do: public_url() <> "/d/" <> id
  defp url_for(%Roll{id: id}), do: public_url() <> "/rolls/" <> id
  defp url_for(%DockerBuild{id: id}), do: public_url() <> "/docker-builds/" <> id

  defp url_for(%BuildBuddyInvocation{id: id}),
    do: public_url() <> "/buildbuddy-invocations/" <> id

  defp url_for(%ProgressItem{id: id}), do: public_url() <> "/?tab=progress#" <> id
  defp url_for(%NoMistakesRun{id: id}), do: public_url() <> "/?tab=no-mistakes#" <> id

  defp public_url do
    Application.get_env(:firstmate_port, :public_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  defp decode_bin(_field, nil), do: {:ok, nil}
  defp decode_bin(_field, ""), do: {:ok, nil}

  defp decode_bin(field, value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, field}
    end
  end

  defp decode_bin(field, _value), do: {:error, field}
end
