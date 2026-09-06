defmodule FirstmatePort.Fleet.Projection do
  @moduledoc """
  Turns a fleet-log record into the JSON and the text a document is built from.

  Pure functions over structs the portal already has. `from/1` returns the
  attributes `FirstmatePort.Fleet.Document`'s upsert accepts, so the sync is a
  map and a write with nothing in between.

  ## What the text looks like

  `search_text` is the document's fields, in sorted key order, one `key: value`
  line each, empty values dropped. That shape does two jobs: it is a canonical
  serialisation of the JSON, so `content_hash` over it detects any change worth
  re-indexing, and it reads as labelled prose, which is what an embedding model
  handles best.

  ## What it leaves out

  Diagram HTML, PNG, and SVG payloads are never projected - they are blobs, and
  the title and notes are the searchable part. no-mistakes `logs` are left out
  too: high volume, low search value, and the text of a document is what an
  embedding provider would receive if an operator turns embeddings on.

  Values are capped at 2,000 characters each and the text at 8,000 overall,
  which keeps one runaway log out of the tsvector limit and out of a provider's
  token limit. Null bytes are stripped: Postgres rejects them even though they
  are valid UTF-8.
  """

  alias FirstmatePort.Portal.{Diagram, GithubItem, NoMistakesRun, ProgressItem, Roll}

  @value_limit 2_000
  @text_limit 8_000

  @sources [GithubItem, ProgressItem, Roll, NoMistakesRun, Diagram]

  @doc "The portal resources a fleet log is projected from, in sync order."
  def sources, do: @sources

  @doc """
  The columns `from/1` reads from a source resource.

  The sync selects exactly these. It is why a sync never loads diagram HTML or
  no-mistakes logs, however large they have grown.
  """
  def select(GithubItem) do
    [
      :id,
      :kind,
      :html_url,
      :title,
      :state,
      :check_status,
      :buildbuddy_url,
      :firewall_verdict,
      :assignment_task_id,
      :assignment_worker,
      :assignment_status,
      :github_updated_at,
      :updated_at
    ]
  end

  def select(ProgressItem), do: [:id, :kind, :title, :url, :body, :updated_at]

  def select(Roll) do
    [
      :id,
      :cluster,
      :namespace,
      :status,
      :image_tag,
      :rebuilt,
      :copied,
      :helm_revision,
      :pr_url,
      :issue_url,
      :outcome,
      :inserted_at
    ]
  end

  def select(NoMistakesRun) do
    [
      :id,
      :run_id,
      :branch,
      :step,
      :findings,
      :outcome,
      :intent,
      :public_summary,
      :pr_url,
      :firewall_verdict,
      :respond_action,
      :respond_findings,
      :respond_instructions,
      :updated_at
    ]
  end

  def select(Diagram), do: [:id, :title, :notes, :inserted_at]

  @doc "Projects one record. Returns the attributes `Document`'s `:upsert` accepts."
  def from(%GithubItem{} = item) do
    build(:github_item, item.id, item.title, item.html_url, "", occurred_at(item), %{
      "kind" => item.kind,
      "html_url" => item.html_url,
      "title" => item.title,
      "state" => item.state,
      "check_status" => item.check_status,
      "buildbuddy_url" => item.buildbuddy_url,
      "firewall_verdict" => item.firewall_verdict,
      "assignment_task_id" => item.assignment_task_id,
      "assignment_worker" => item.assignment_worker,
      "assignment_status" => item.assignment_status
    })
  end

  def from(%ProgressItem{} = item) do
    build(:progress_item, item.id, item.title, item.url, item.body, item.updated_at, %{
      "kind" => item.kind,
      "title" => item.title,
      "url" => item.url,
      "body" => item.body
    })
  end

  def from(%Roll{} = roll) do
    title = "#{roll.cluster}/#{roll.namespace} #{roll.status} #{roll.image_tag}"

    build(:roll, roll.id, title, roll.pr_url, roll.outcome, roll.inserted_at, %{
      "cluster" => roll.cluster,
      "namespace" => roll.namespace,
      "status" => roll.status,
      "image_tag" => roll.image_tag,
      "rebuilt" => roll.rebuilt,
      "copied" => roll.copied,
      "helm_revision" => roll.helm_revision,
      "pr_url" => roll.pr_url,
      "issue_url" => roll.issue_url,
      "outcome" => roll.outcome
    })
  end

  def from(%NoMistakesRun{} = run) do
    title = "#{run.branch} #{run.run_id}"

    build(:no_mistakes_run, run.id, title, run.pr_url, run.findings, run.updated_at, %{
      "run_id" => run.run_id,
      "branch" => run.branch,
      "step" => run.step,
      "findings" => run.findings,
      "outcome" => run.outcome,
      "intent" => run.intent,
      "public_summary" => run.public_summary,
      "pr_url" => run.pr_url,
      "firewall_verdict" => run.firewall_verdict,
      "respond_action" => run.respond_action,
      "respond_findings" => run.respond_findings,
      "respond_instructions" => run.respond_instructions
    })
  end

  def from(%Diagram{} = diagram) do
    build(:diagram, diagram.id, diagram.title, "", diagram.notes, diagram.inserted_at, %{
      "title" => diagram.title,
      "notes" => diagram.notes
    })
  end

  @doc """
  The canonical text for a JSON document: sorted `key: value` lines, empties
  dropped, values and total length capped.
  """
  def search_text(document) when is_map(document) do
    document
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} ->
      case flatten(value) do
        "" -> []
        text -> ["#{key}: #{text}"]
      end
    end)
    |> Enum.join("\n")
    |> String.slice(0, @text_limit)
  end

  @doc "Digest of the canonical text. Equal digests mean nothing worth re-indexing changed."
  def content_hash(search_text) when is_binary(search_text) do
    :sha256 |> :crypto.hash(search_text) |> Base.encode16(case: :lower)
  end

  defp build(source, source_id, title, url, body, occurred_at, values) do
    document = Map.new(values, fn {key, value} -> {key, jsonable(value)} end)
    text = search_text(document)

    %{
      source: source,
      source_id: source_id,
      title: clean(title),
      url: clean(url),
      body: clean(body),
      document: document,
      search_text: text,
      content_hash: content_hash(text),
      occurred_at: occurred_at
    }
  end

  defp occurred_at(%GithubItem{github_updated_at: nil, updated_at: updated_at}), do: updated_at
  defp occurred_at(%GithubItem{github_updated_at: at}), do: at

  # jsonb only holds JSON, so atoms become their names and lists keep their
  # element order. Nothing here is nested deeper than a list of strings.
  defp jsonable(nil), do: ""
  defp jsonable(value) when is_atom(value) and value not in [true, false], do: to_string(value)
  defp jsonable(value) when is_binary(value), do: clean(value)
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value), do: value

  defp flatten(value) when is_binary(value), do: String.trim(value)

  defp flatten(value) when is_list(value),
    do: value |> Enum.map_join(" ", &flatten/1) |> String.trim()

  defp flatten(nil), do: ""
  defp flatten(value), do: value |> to_string() |> String.trim()

  defp clean(nil), do: ""

  defp clean(value) when is_binary(value) do
    value
    |> String.replace("\x00", "")
    |> String.slice(0, @value_limit)
  end

  defp clean(value), do: value |> to_string() |> clean()
end
