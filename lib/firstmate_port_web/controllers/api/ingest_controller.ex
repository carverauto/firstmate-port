defmodule FirstmatePortWeb.Api.IngestController do
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Portal.{Diagram, NoMistakesRun, ProgressItem, Roll}

  def create_diagram(conn, params) do
    actor = conn.assigns.current_user

    attrs = %{
      id: params["id"],
      title: params["title"] || "untitled",
      notes: params["notes"] || "",
      html: decode_bin(params["html"] || params["html_base64"]),
      png: decode_bin(params["png_base64"]),
      svg: decode_bin(params["svg"])
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
  end

  def create_progress(conn, params) do
    record(conn, ProgressItem, :record, %{
      kind: params["kind"],
      title: params["title"],
      url: params["url"] || "",
      body: params["body"] || ""
    })
  end

  def create_roll(conn, params) do
    record(conn, Roll, :record, %{
      cluster: params["cluster"] || "farm01",
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
  def list_progress(conn, _params), do: list(conn, ProgressItem)
  def list_rolls(conn, _params), do: list(conn, Roll)
  def list_no_mistakes(conn, _params), do: list(conn, NoMistakesRun)

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

  defp url_for(%Diagram{id: id}), do: public_url() <> "/d/" <> id
  defp url_for(%Roll{id: id}), do: public_url() <> "/rolls/" <> id
  defp url_for(%ProgressItem{id: id}), do: public_url() <> "/?tab=progress#" <> id
  defp url_for(%NoMistakesRun{id: id}), do: public_url() <> "/?tab=no-mistakes#" <> id

  defp public_url do
    Application.get_env(:firstmate_port, :public_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  defp decode_bin(nil), do: nil
  defp decode_bin(""), do: nil

  defp decode_bin(value) when is_binary(value) do
    case Base.decode64(value, padding: false) do
      {:ok, bin} ->
        bin

      :error ->
        case Base.decode64(value) do
          {:ok, bin} -> bin
          :error -> value
        end
    end
  end
end
