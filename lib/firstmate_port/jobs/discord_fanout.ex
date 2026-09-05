defmodule FirstmatePort.Jobs.DiscordFanout do
  @moduledoc """
  Short Discord pings with a portal URL. Never dumps helm output, findings,
  matching snippets, or customer names. Public failures stay generic.
  """

  use Oban.Worker, queue: :discord, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "id" => id}}) do
    webhook = Application.get_env(:firstmate_port, :discord_webhook_url)

    if is_nil(webhook) or webhook == "" do
      :ok
    else
      case render(kind, id) do
        nil -> :ok
        text -> post(webhook, text)
      end
    end
  end

  defp render("diagram", id) do
    "**Archify diagram** #{public_url()}/d/#{id}"
  end

  defp render("progress", id) do
    "**Progress** #{public_url()}/?tab=progress##{id}"
  end

  defp render("roll", id) do
    "**Roll** #{public_url()}/rolls/#{id}"
  end

  defp render("no_mistakes", id) do
    # Generic on every public surface. Findings stay on the LAN portal.
    "**no-mistakes** #{generic_nm(id)} #{public_url()}/no-mistakes"
  end

  defp render(_, _), do: nil

  defp generic_nm(id) do
    case FirstmatePort.Portal.NoMistakesRun.get(id,
           authorize?: false,
           tenant: FirstmatePort.Tenancy.schema_for(FirstmatePort.Tenancy.default_slug())
         ) do
      {:ok, %{outcome: outcome}} when outcome in ["failed", "cancelled", "failure"] ->
        "failed"

      {:ok, %{outcome: outcome}} when is_binary(outcome) and outcome != "" ->
        "update"

      _ ->
        "update"
    end
  end

  defp public_url do
    Application.get_env(:firstmate_port, :public_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  defp post(webhook, content) do
    case Req.post(webhook, json: %{content: String.slice(content, 0, 1900)}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end
end
