defmodule FirstmatePort.Router.ProviderIntel do
  @moduledoc """
  Optional provider input for routing. Artificial Analysis (quality /
  latency benchmarks) annotates the answer for the chosen lane. It never
  picks the lane or the model: the fleet matrix plus the bundled eval set
  decide, and no public source outvotes them.

  Opt-in per request (`POST /api/route` with `"intel": true`) and gated on
  `AA_API_KEY` (paid API). With no key and no network, `fetch/0` returns
  `%{benchmarks: [], sources: []}` and routing runs fully offline.
  """

  @doc """
  Fetch provider intel. Never raises: any failure yields empty intel so the
  router falls back to matrix + evals and says so in `intel_sources`.
  """
  def fetch(opts \\ []) do
    http = Keyword.get(opts, :http, &default_http/1)

    %{benchmarks: fetch_aa_benchmarks(http), sources: []}
    |> with_sources()
  end

  @doc "Source names contributed by an intel map (for `intel_sources`)."
  def sources(nil), do: []
  def sources(%{sources: sources}), do: sources
  def sources(_), do: []

  @doc """
  Name the model for the chosen harness lane at `effort`.

  Returns `{model, model_source, reasons}`. The id comes from the fleet
  matrix, which names a concrete model per lane and effort — never a
  placeholder. AA benchmarks only annotate the reason; no provider catalog
  narrows the pick.
  """
  def select_model(harness, effort, intel) do
    benchmarks = if is_map(intel), do: Map.get(intel, :benchmarks, []), else: []
    model = FirstmatePort.Router.Matrix.model(harness, effort)

    {model, "fleet_matrix",
     [
       "model=#{model}: the #{harness} lane runs it at #{effort} effort" <>
         quality_note(harness, benchmarks)
     ]}
  end

  # -- fetching ----------------------------------------------------------

  defp with_sources(%{benchmarks: []} = intel), do: intel
  defp with_sources(intel), do: %{intel | sources: ["artificial-analysis"]}

  defp fetch_aa_benchmarks(http) do
    case System.get_env("AA_API_KEY") do
      nil ->
        []

      "" ->
        []

      key ->
        url = aa_url()

        case http.({url, [{"authorization", "Bearer #{key}"}]}) do
          {:ok, %{"data" => rows}} when is_list(rows) -> Enum.take(rows, 50)
          _ -> []
        end
    end
  end

  defp default_http({url, headers}) do
    req =
      Req.new(url: url, headers: headers, receive_timeout: 8_000)
      |> Req.get()

    case req do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: _}} -> {:error, :http}
      {:error, _} = err -> err
    end
  rescue
    _ -> {:error, :http}
  end

  defp aa_url do
    Application.get_env(:firstmate_port, :aa_benchmarks_url) ||
      "https://artificialanalysis.ai/api/v2/data/llms/models"
  end

  defp quality_note(_harness, []), do: ""

  defp quality_note(harness, benchmarks) do
    case Enum.find(benchmarks, &match_family?(&1, harness)) do
      nil -> ""
      row -> "; Artificial Analysis notes #{inspect(score_of(row))} for the family"
    end
  end

  defp match_family?(row, harness) when is_map(row) do
    name =
      (Map.get(row, "model") || Map.get(row, "slug") || "") |> to_string() |> String.downcase()

    String.contains?(name, harness)
  end

  defp score_of(row) do
    Map.get(row, "quality_score") || Map.get(row, "score") || "a benchmark entry"
  end
end
