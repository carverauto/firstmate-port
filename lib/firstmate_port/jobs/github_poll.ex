defmodule FirstmatePort.Jobs.GitHubPoll do
  @moduledoc """
  Mirrors an organisation's open PRs and issues onto the `GithubItem` board, and
  **enriches** the fleet log — it is never the fleet log's catalogue.

  Progress tracks crew work: the PRs, issues, and tasks this fleet actually
  worked, reviewed, or closed. Those rows arrive from firstmate and fm-steer,
  which know who did the work. This poll only speaks for rows that already
  exist: it refreshes their title and appends a `:status` event when a PR merges
  or an issue closes. It cannot create a `ProgressItem` — `:record` requires a
  worker, and an org listing has none to name.

  That is deliberate, and it is what keeps `/progress` from filling with every
  dependency bump in the organisation.

  Two passes over the search API. The open pass keeps the `GithubItem` board
  current, because that board *is* a mirror of open org work. The closed pass
  exists only to move the status of fleet-log rows onto merged or complete.
  Neither pass grows `progress_items`.
  """

  require Logger

  alias FirstmatePort.Portal.{ProgressItem, ProgressLog, ProgressStatus}

  @spec run(term()) :: :ok
  def run(actor) do
    token = trim_credential(System.get_env("GITHUB_TOKEN"))
    org = String.trim(System.get_env("GITHUB_ORG") || "")

    cond do
      is_nil(token) or token == "" ->
        Logger.info("GitHub poll skipped: GITHUB_TOKEN unset")
        :ok

      org == "" ->
        Logger.info("GitHub poll skipped: GITHUB_ORG unset")
        :ok

      true ->
        poll_search(org, token, actor, :pr, "is:pr+is:open", :board)
        poll_search(org, token, actor, :issue, "is:issue+is:open", :board)
        poll_search(org, token, actor, :pr, "is:pr+is:closed", :enrich)
        poll_search(org, token, actor, :issue, "is:issue+is:closed", :enrich)
        :ok
    end
  end

  @doc """
  Trims a credential env value. Secret stores routinely append a trailing
  newline, which makes the value invalid as an HTTP header character-for-character.
  """
  @spec trim_credential(String.t() | nil) :: String.t() | nil
  def trim_credential(nil), do: nil
  def trim_credential(""), do: ""
  def trim_credential(value) when is_binary(value), do: String.trim(value)

  defp poll_search(org, token, actor, kind, extra, mode) do
    url =
      "https://api.github.com/search/issues?q=org:#{org}+#{extra}" <>
        "&per_page=50&sort=updated&order=desc"

    case get_json(url, token) do
      {:ok, %{"items" => items}} ->
        Enum.each(items, &handle_item(&1, kind, token, actor, mode))

      {:error, reason} ->
        Logger.warning("GitHub #{kind} #{mode} poll failed: #{inspect(reason)}")
    end
  end

  defp handle_item(item, kind, token, actor, :board), do: upsert_item(item, kind, token, actor)

  defp handle_item(item, kind, _token, actor, :enrich),
    do: enrich_progress(item, kind, actor)

  defp upsert_item(%{"html_url" => html_url, "title" => title} = item, kind, token, actor)
       when is_binary(html_url) do
    {check_status, buildbuddy_url} = checks_for(item, token)

    FirstmatePort.Portal.GithubItem.upsert(
      %{
        kind: kind,
        html_url: html_url,
        title: title,
        state: :open,
        check_status: check_status,
        buildbuddy_url: buildbuddy_url || "",
        github_updated_at: parse_time(item["updated_at"])
      },
      FirstmatePort.Tenancy.opts(actor || agent_actor())
    )

    enrich_progress(item, kind, actor)
  end

  defp upsert_item(_, _, _, _), do: :ok

  defp checks_for(%{"pull_request" => _} = item, token) do
    case item["repository_url"] do
      "https://api.github.com/repos/" <> rest ->
        sha = get_in(item, ["pull_request", "url"])
        _ = sha
        checks_from_repo(rest, item, token)

      _ ->
        {:none, ""}
    end
  end

  defp checks_for(_, _), do: {:none, ""}

  defp checks_from_repo(repo, item, token) do
    pr_api = get_in(item, ["pull_request", "url"])

    with true <- is_binary(pr_api),
         {:ok, %{"head" => %{"sha" => sha}}} <- get_json(pr_api, token),
         {:ok, %{"check_runs" => runs}} <-
           get_json("https://api.github.com/repos/#{repo}/commits/#{sha}/check-runs", token) do
      {status_from_runs(runs), buildbuddy_from_runs(runs)}
    else
      _ -> {:none, ""}
    end
  end

  defp status_from_runs(runs) do
    statuses = Enum.map(runs, &check_run_status/1)

    cond do
      Enum.any?(statuses, &(&1 == :failure)) -> :failure
      Enum.any?(statuses, &(&1 == :running)) -> :running
      Enum.any?(statuses, &(&1 == :queued)) -> :queued
      Enum.any?(statuses, &(&1 == :success)) -> :success
      true -> :none
    end
  end

  defp check_run_status(%{"status" => "queued"}), do: :queued
  defp check_run_status(%{"status" => "in_progress"}), do: :running
  defp check_run_status(%{"conclusion" => "success"}), do: :success

  defp check_run_status(%{"conclusion" => conclusion})
       when conclusion in ["failure", "cancelled", "timed_out"], do: :failure

  defp check_run_status(_), do: :none

  def copied_buildbuddy_url(runs) when is_list(runs) do
    runs
    |> Enum.map(fn run -> run["details_url"] || run["html_url"] || "" end)
    |> Enum.find("", fn url ->
      String.contains?(url, "buildbuddy") and String.contains?(url, "/invocation/")
    end)
  end

  defp buildbuddy_from_runs(runs), do: copied_buildbuddy_url(runs)

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc """
  Enriches the fleet-log row for one GitHub search result, if there is one.

  A URL nobody on this crew ever logged is skipped: the poll refreshes and moves
  rows, it does not catalogue an organisation. Public so the contract itself is
  testable — see `test/firstmate_port/github_poll_test.exs`.
  """
  @spec enrich_progress(map(), :pr | :issue, term()) :: :ok
  def enrich_progress(%{"html_url" => html_url, "title" => title} = raw, kind, actor)
      when is_binary(html_url) do
    opts = FirstmatePort.Tenancy.opts(actor || agent_actor())

    case ProgressItem.get_by_url(html_url, opts) do
      {:ok, item} when not is_nil(item) ->
        item
        |> touch_if_changed(kind, title, opts)
        |> append_status(kind, raw, opts)

      _ ->
        :ok
    end
  end

  def enrich_progress(_raw, _kind, _actor), do: :ok

  defp touch_if_changed(existing, kind, title, opts) do
    if progress_changed?(existing, kind, title) do
      case ProgressItem.touch(existing, %{kind: kind, title: title}, opts) do
        {:ok, touched} -> touched
        _ -> existing
      end
    else
      existing
    end
  end

  # Appends only when the status actually moved, so a poll that runs every few
  # minutes does not fill the log with identical rows.
  defp append_status(item, kind, raw, opts) do
    status = ProgressStatus.from_github(kind, raw)

    case ProgressLog.record_observed_status(item, status, %{detail: "github poll"}, opts) do
      {:ok, _outcome, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("GitHub poll could not append status for #{item.id}: #{inspect(reason)}")
        :ok
    end
  end

  def progress_changed?(existing, kind, title) do
    existing.kind != kind or existing.title != title
  end

  defp agent_actor do
    %{
      role: :agent,
      email: "agent@localhost",
      id: "github-poll",
      tenant_slug: FirstmatePort.Tenancy.default_slug()
    }
  end

  defp get_json(url, token) do
    req =
      Req.new(
        url: url,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"},
          {"user-agent", "firstmate-port"}
        ]
      )

    case Req.get(req) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      other -> {:error, other}
    end
  end
end
