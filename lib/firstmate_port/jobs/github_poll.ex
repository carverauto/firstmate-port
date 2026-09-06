defmodule FirstmatePort.Jobs.GitHubPoll do
  @moduledoc """
  Copies GitHub PR and closed-issue html_url values as given by the API.
  """

  require Logger

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
        poll_search(org, token, actor, :pr, "is:pr+is:open")
        poll_search(org, token, actor, :issue, "is:issue+is:open")

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

  defp poll_search(org, token, actor, kind, extra) do
    url = "https://api.github.com/search/issues?q=org:#{org}+#{extra}&per_page=50"

    case get_json(url, token) do
      {:ok, %{"items" => items}} ->
        Enum.each(items, &upsert_item(&1, kind, token, actor))

      {:error, reason} ->
        Logger.warning("GitHub #{kind} poll failed: #{inspect(reason)}")
    end
  end

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

    record_item(item, kind, actor)
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

  defp record_item(%{"html_url" => html_url, "title" => title}, kind, actor)
       when is_binary(html_url) do
    actor = actor || agent_actor()

    case FirstmatePort.Portal.ProgressItem.get_by_url(
           html_url,
           FirstmatePort.Tenancy.opts(actor)
         ) do
      {:ok, existing} ->
        if progress_changed?(existing, kind, title) do
          FirstmatePort.Portal.ProgressItem.touch(
            existing,
            %{kind: kind, title: title},
            FirstmatePort.Tenancy.opts(actor)
          )
        else
          :ok
        end

      _ ->
        FirstmatePort.Portal.ProgressItem.record(
          %{kind: kind, title: title, url: html_url, body: ""},
          FirstmatePort.Tenancy.opts(actor)
        )
    end
  end

  defp record_item(_, _, _), do: :ok

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
