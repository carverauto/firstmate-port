defmodule FirstmatePort.BuildBuddy do
  @moduledoc """
  Minimal BuildBuddy API client over the Connect/JSON RPC surface.

  Calls `POST {host}/rpc/BuildBuddyService/<Method>` with the org API key
  in the `x-buildbuddy-api-key` header and proto3 JSON bodies. The key is
  read from `FirstmatePort.BuildTracking` (env `BUILDBUDDY_ORG_API_KEY`
  supplied as a Kubernetes or Docker secret) and is never logged.

  API calls use the configured `BUILDBUDDY_HOST`.
  """

  alias FirstmatePort.BuildTracking

  @api_key_header "x-buildbuddy-api-key"

  @doc "True when an org API key is configured."
  def configured?, do: BuildTracking.buildbuddy_enabled?()

  @doc "Default host for API calls and invocation links, if configured."
  def host, do: BuildTracking.buildbuddy_host()

  @doc """
  Web URL for an invocation, e.g. `https://host/invocation/<id>`.
  Returns nil when no host is given or configured.
  """
  def invocation_url(id) when not is_binary(id) or id == "", do: nil

  def invocation_url(id) do
    case host() do
      nil -> nil
      host -> String.trim_trailing(host, "/") <> "/invocation/#{id}"
    end
  end

  @doc """
  Fetch one invocation via `GetInvocation`. Returns `{:ok, map}` with a
  normalized subset (`invocation_id`, `status`, `commit_sha`, `branch`,
  `repo_url`, `host`, `url`) plus the raw payload under `:raw`.

  Options: `:req_options` merged
  into the underlying `Req.new/1` (used by tests to stub HTTP).
  """
  def get_invocation(invocation_id, opts \\ []) do
    with {:ok, {host, key}} <- credentials(),
         :ok <- require_id(invocation_id) do
      body = %{
        "requestContext" => %{},
        "lookup" => %{"invocationId" => invocation_id, "fetchChildInvocations" => false}
      }

      case rpc(host, key, "GetInvocation", body, opts) do
        {:ok, %{"invocation" => [inv | _]}} -> {:ok, normalize(inv, host)}
        {:ok, %{"invocation" => inv}} when is_map(inv) -> {:ok, normalize(inv, host)}
        {:ok, other} when is_map(other) -> {:error, {:unexpected_response, other}}
        {:error, _} = err -> err
      end
    end
  end

  defp credentials() do
    host = host()

    cond do
      BuildTracking.api_key() in [nil, ""] -> {:error, :unconfigured}
      host in [nil, ""] -> {:error, :no_host}
      true -> {:ok, {String.trim_trailing(host, "/"), BuildTracking.api_key()}}
    end
  end

  defp require_id(id) when is_binary(id) and id != "", do: :ok
  defp require_id(_), do: {:error, :invalid_invocation_id}

  defp rpc(host, key, method, body, opts) do
    req =
      Req.new(
        [headers: [{@api_key_header, key}], retry: false]
        |> Keyword.merge(opts[:req_options] || [])
      )

    case Req.post(req, url: host <> "/rpc/BuildBuddyService/" <> method, json: body) do
      {:ok, %Req.Response{status: 200, body: decoded}} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, %Req.Response{status: status, body: decoded}} ->
        {:error, {:http, status, redact(decoded)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp normalize(inv, host) when is_map(inv) do
    id = field(inv, ["invocationId", "invocation_id"]) || ""

    %{
      invocation_id: id,
      status: field(inv, ["invocationStatus", "invocation_status"]) || "",
      commit_sha: field(inv, ["commitSha", "commit_sha"]) || "",
      branch: field(inv, ["branchName", "branch_name"]) || "",
      repo_url: field(inv, ["repoUrl", "repo_url"]) || "",
      host: host,
      url: invocation_url(id),
      raw: inv
    }
  end

  defp field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        "" -> nil
        nil -> nil
        value -> value
      end
    end)
  end

  # Error bodies can echo request context; keep only a short summary.
  defp redact(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp redact(%{"error" => message}) when is_binary(message), do: String.slice(message, 0, 200)
  defp redact(_), do: "request failed"
end
