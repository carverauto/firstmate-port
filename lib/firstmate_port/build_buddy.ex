defmodule FirstmatePort.BuildBuddy do
  @moduledoc """
  Minimal BuildBuddy API client over the Connect/JSON RPC surface.

  Calls `POST {host}/rpc/BuildBuddyService/<Method>` with the org API key
  in the `x-buildbuddy-api-key` header and proto3 JSON bodies. The key is
  read from `FirstmatePort.BuildTracking` (env `BUILDBUDDY_ORG_API_KEY`
  supplied as a Kubernetes or Docker secret) and is never logged.

  Any BuildBuddy host works; the configured `BUILDBUDDY_HOST` is only the
  default and can be overridden per call or per recorded invocation.
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
  def invocation_url(invocation_id, host \\ nil)

  def invocation_url(id, _host) when not is_binary(id) or id == "", do: nil

  def invocation_url(id, nil) do
    case host() do
      nil -> nil
      h -> invocation_url(id, h)
    end
  end

  def invocation_url(id, host) do
    host |> String.trim_trailing("/") |> Kernel.<>("/invocation/#{id}")
  end

  @doc """
  Split a copied BuildBuddy invocation URL into host and invocation id.

  Returns `{:ok, %{host: host, invocation_id: id}}` or `:error`.
  """
  def parse_invocation_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: s, host: h, path: "/invocation/" <> id}
      when s in ["http", "https"] and is_binary(h) and h != "" ->
        id = id |> String.split("/") |> List.first("") |> String.trim()

        if id == "" do
          :error
        else
          {:ok, %{host: "#{s}://#{h}", invocation_id: id}}
        end

      _ ->
        :error
    end
  end

  def parse_invocation_url(_), do: :error

  @doc """
  Fetch one invocation via `GetInvocation`. Returns `{:ok, map}` with a
  normalized subset (`invocation_id`, `status`, `commit_sha`, `branch`,
  `repo_url`, `host`, `url`) plus the raw payload under `:raw`.

  Options: `:host` to override the configured host, `:req_options` merged
  into the underlying `Req.new/1` (used by tests to stub HTTP).
  """
  def get_invocation(invocation_id, opts \\ []) do
    with {:ok, {host, key}} <- credentials(opts),
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

  @doc """
  List recent invocations via `SearchInvocation`, newest first.

  Options: `:host`, `:req_options` (as in `get_invocation/2`), plus query
  filters `:repo_url`, `:branch`, `:status` (e.g. `"FAILED"`), `:count`
  (default 25), `:updated_after`, `:updated_before` (ISO8601), and
  `:group_id` when the org needs an explicit request context.
  """
  def recent_invocations(opts \\ []) do
    with {:ok, {host, key}} <- credentials(opts) do
      query =
        %{
          "repoUrl" => opts[:repo_url],
          "branchName" => opts[:branch],
          "invocationStatus" => List.wrap(opts[:status] || []),
          "updatedAfter" => opts[:updated_after],
          "updatedBefore" => opts[:updated_before]
        }
        |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
        |> Map.new()

      context =
        case opts[:group_id] do
          nil -> %{}
          group -> %{"groupId" => group}
        end

      body = %{
        "requestContext" => context,
        "query" => query,
        "sort" => %{"sortField" => "UPDATED_AT_USEC_SORT_FIELD", "ascending" => false},
        "count" => opts[:count] || 25
      }

      case rpc(host, key, "SearchInvocation", body, opts) do
        {:ok, %{"invocation" => invs}} when is_list(invs) ->
          {:ok, Enum.map(invs, &normalize(&1, host))}

        {:ok, other} when is_map(other) ->
          {:error, {:unexpected_response, other}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp credentials(opts) do
    host = opts[:host] || host()

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
      url: invocation_url(id, host),
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
