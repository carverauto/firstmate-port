defmodule FirstmatePort.Router.ProviderIntel do
  @moduledoc """
  Optional provider inputs for routing. OpenRouter (model metadata, pricing,
  context) and Artificial Analysis (quality / latency benchmarks) inform the
  *model pick inside the chosen lane only*. They never pick the lane: the
  fleet matrix plus the bundled eval set always outvote any single public
  source, and popularity is never treated as capability.

  Both sources are opt-in per request (`POST /api/route` with
  `"intel": true`) and need no API key to read. Keys only raise limits:

  - `OPENROUTER_API_KEY` — also enables usage sync in `FirstmatePort.Usage.Sync`.
  - `AA_API_KEY` — Artificial Analysis benchmarks (paid API).

  With no keys and no network, `fetch/0` returns `%{models: [],
  benchmarks: [], sources: []}` and routing runs fully offline.
  """

  @openrouter_models_url "https://openrouter.ai/api/v1/models"

  @doc """
  Fetch provider intel. Never raises: any failure yields empty intel so the
  router falls back to matrix + evals and says so in `intel_sources`.
  """
  def fetch(opts \\ []) do
    http = Keyword.get(opts, :http, &default_http/1)

    %{
      models: fetch_openrouter_models(http),
      benchmarks: fetch_aa_benchmarks(http),
      sources: []
    }
    |> with_sources()
  end

  @doc "Source names contributed by an intel map (for `intel_sources`)."
  def sources(nil), do: []
  def sources(%{sources: sources}), do: sources
  def sources(_), do: []

  @doc """
  Pick a concrete model id for the chosen harness lane.

  Returns `{model, model_source, reasons}`. Without intel the harness uses
  its own default (`"harness-default"`); intel narrows to the cheapest
  OpenRouter model in the harness family with enough context. AA benchmarks
  attach a quality note but never change the lane.
  """
  def select_model(harness, intel) do
    models = if is_map(intel), do: Map.get(intel, :models, []), else: []
    benchmarks = if is_map(intel), do: Map.get(intel, :benchmarks, []), else: []

    case cheapest_family_model(harness, models) do
      nil ->
        {"harness-default", "harness_default",
         ["model=harness-default: #{harness} resolves its own default model"]}

      id ->
        note = quality_note(harness, benchmarks)

        {"#{id}", "openrouter",
         [
           "model=#{id}: cheapest OpenRouter #{harness}-family model with room for the task" <>
             note
         ]}
    end
  end

  @doc """
  Parse an OpenRouter `/api/v1/models` body into
  `[%{id:, prompt_price:, completion_price:, context:}]`. Pure: safe to test.
  """
  def parse_openrouter_models(%{"data" => rows}) when is_list(rows) do
    Enum.flat_map(rows, fn
      %{"id" => id} = row when is_binary(id) ->
        [
          %{
            id: id,
            prompt_price: get_in(row, ["pricing", "prompt"]) |> to_price(),
            completion_price: get_in(row, ["pricing", "completion"]) |> to_price(),
            context: Map.get(row, "context_length", 0)
          }
        ]

      _ ->
        []
    end)
  end

  def parse_openrouter_models(_), do: []

  # -- fetching ----------------------------------------------------------

  defp with_sources(%{models: [], benchmarks: []} = intel), do: intel

  defp with_sources(%{models: models, benchmarks: benchmarks} = intel) do
    sources =
      if(models == [], do: [], else: ["openrouter"]) ++
        if benchmarks == [], do: [], else: ["artificial-analysis"]

    %{intel | sources: sources}
  end

  defp fetch_openrouter_models(http) do
    headers = base_headers() ++ api_key_header("OPENROUTER_API_KEY")

    case http.({@openrouter_models_url, headers}) do
      {:ok, %{"data" => _} = body} -> parse_openrouter_models(body)
      _ -> []
    end
  end

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

  defp base_headers do
    [{"user-agent", "firstmate-port/router"}, {"accept", "application/json"}]
  end

  defp api_key_header(env) do
    case System.get_env(env) do
      nil -> []
      "" -> []
      key -> [{"authorization", "Bearer #{key}"}]
    end
  end

  defp aa_url do
    Application.get_env(:firstmate_port, :aa_benchmarks_url) ||
      "https://artificialanalysis.ai/api/v2/data/llms/models"
  end

  # -- model picking ------------------------------------------------------

  @families %{
    "claude" => ["anthropic/"],
    "codex" => ["openai/"],
    "grok" => ["x-ai/"],
    "opencode" => ["openrouter/", "meta-llama/", "qwen/", "google/"]
  }

  defp cheapest_family_model(harness, models) do
    prefixes = Map.get(@families, harness, [])

    models
    |> Enum.filter(fn m ->
      Enum.any?(prefixes, &String.starts_with?(m.id, &1)) and (m.context || 0) >= 32_000
    end)
    |> Enum.sort_by(&{price_rank(&1.prompt_price), -&1.context})
    |> List.first()
    |> case do
      nil -> nil
      %{id: id} -> id
    end
  end

  # Unpriced models sort after priced ones; prices are plain floats
  # (metadata ranking only, never money math).
  defp price_rank(nil), do: {1, 0.0}
  defp price_rank(p), do: {0, p}

  defp to_price(nil), do: nil
  defp to_price(p) when is_number(p), do: p * 1.0

  defp to_price(p) when is_binary(p) do
    case Float.parse(p) do
      {f, _} -> f
      :error -> nil
    end
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
