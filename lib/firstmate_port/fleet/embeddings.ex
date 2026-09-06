defmodule FirstmatePort.Fleet.Embeddings do
  @moduledoc """
  Optional semantic search: the operator's model, the tenant's key.

  Embeddings are off until two things are true. A model spec - `provider:model`,
  see `catalog/0` - is set, either on the tenant or as the deployment default in
  `FLEET_EMBEDDINGS_MODEL`. And the tenant has filled the `embeddings`/`api_key`
  credential slot in the portal. Until both hold, `FirstmatePort.Fleet.Search`
  runs on Postgres text search alone and nothing leaves the cluster.

  The key follows the same path as every other tenant secret: typed into the
  portal, `AshCloak`-encrypted in the shared database, read back server-side
  only here. It is never in git, never in a per-tenant Kubernetes secret, and
  never passed through application environment where a second tenant's request
  could pick it up. See `docs/credentials.md`.

  ## What an operator is agreeing to

  Turning embeddings on sends the indexed text of the fleet log to the chosen
  provider - PR and issue titles, roll outcomes, no-mistakes findings and
  intents. `FirstmatePort.Fleet.Projection` already leaves out diagram payloads
  and no-mistakes logs, but everything else it keeps is text a provider will
  see. `docs/fleet-search.md` says so where an operator will read it.
  """

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Credentials
  alias FirstmatePort.Tenancy

  @provider "embeddings"
  @key "api_key"

  # `provider:model`. The model half allows `/` because aggregating providers
  # namespace their models, e.g. `openrouter:baai/bge-m3`.
  @spec_shape ~r{^([a-z][a-z0-9_-]*):([A-Za-z0-9][A-Za-z0-9._/-]*)$}

  # Known-good specs, for the portal's model list and for the docs. This is a
  # convenience, not a gate: any embedding model the provider library supports
  # can be typed in, which is what "favourite model of the day" needs.
  @catalog [
    %{
      spec: "openai:text-embedding-3-small",
      label: "OpenAI text-embedding-3-small",
      dimensions: 1536
    },
    %{
      spec: "openai:text-embedding-3-large",
      label: "OpenAI text-embedding-3-large",
      dimensions: 3072
    },
    %{
      spec: "google:gemini-embedding-001",
      label: "Gemini gemini-embedding-001",
      dimensions: 3072
    },
    %{spec: "mistral:mistral-embed", label: "Mistral mistral-embed", dimensions: 1024}
  ]

  @doc "Model specs the portal offers by name."
  def catalog, do: @catalog

  @doc "The credential slot the API key goes in."
  def slot, do: {@provider, @key}

  @doc """
  Where a tenant stands: `:off`, `:missing_api_key`, or `{:ready, model_spec}`.

  This is what the portal shows. It never returns the key.
  """
  def state(tenant) do
    slug = Tenancy.slug(tenant)

    case model(slug) do
      :error ->
        :off

      {:ok, spec} ->
        case Credentials.secret(slug, @provider, @key) do
          {:ok, _key} -> {:ready, spec}
          :error -> :missing_api_key
        end
    end
  end

  @doc """
  The model spec for a tenant: its own choice, else the deployment default.

  Returns `:error` when neither is set, which is how embeddings stay off by
  default in a fresh checkout.
  """
  def model(tenant) do
    slug = Tenancy.slug(tenant)

    case tenant_model(slug) do
      {:ok, spec} -> {:ok, spec}
      :error -> default_model()
    end
  end

  @doc "The deployment-wide model spec from configuration, or `:error`."
  def default_model do
    :firstmate_port
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:model)
    |> present()
  end

  @doc """
  Checks a model spec before it is stored.

  Two cheap questions: does it have the shape `provider:model`, and is that a
  provider this build can reach. Both are answered from a compile-time list, in
  microseconds.

  It deliberately stops there. Asking the provider library's model catalogue
  whether that exact model exists costs seconds on its first call - a form
  submit is the wrong place to pay for that, and holding a database connection
  while doing it is worse. The catalogue also lags real providers, so it would
  refuse models released after this build, and guessing from the name refuses
  real ones: `text-embedding-3-small` and `mistral-embed` are named for the job
  but `baai/bge-m3` and `voyage-3` are not.

  So a model that is not an embedding model is caught where it is unambiguous:
  the provider's own error on the next backfill, which `/search` reports rather
  than hiding. The portal's model list exists so the common path never has to
  rely on that.
  """
  def validate_spec(spec) when is_binary(spec) do
    case Regex.run(@spec_shape, spec) do
      [_spec, provider, model] -> validate_parts(provider, model)
      _ -> {:error, "must look like provider:model, for example openai:text-embedding-3-small"}
    end
  end

  def validate_spec(_spec), do: {:error, "must be a string"}

  @doc "Providers this build can reach, as strings, sorted."
  def providers do
    ReqLLM.Providers.list() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  @doc """
  Embeds a list of texts for one tenant.

  Returns `{:ok, %{model: spec, vectors: vectors}}` with unit-normalised
  vectors, `{:error, :disabled}` when no model is configured,
  `{:error, :missing_api_key}` when the tenant has not filled the slot, and the
  provider's own error otherwise.
  """
  def embed(texts, tenant, opts \\ []) when is_list(texts) do
    with {:ok, %{model: model, api_key: api_key}} <- configuration(tenant),
         request_opts = Keyword.put(opts_for_client(opts), :api_key, api_key),
         {:ok, vectors} <- invoke(client(opts), model, texts, request_opts),
         :ok <- check_shape(vectors, texts) do
      {:ok, %{model: model, vectors: Enum.map(vectors, &unit/1)}}
    end
  end

  @doc "Embeds one query string. Same contract as `embed/3`, one vector back."
  def embed_query(text, tenant, opts \\ []) when is_binary(text) do
    with {:ok, %{model: model, vectors: [vector]}} <- embed([text], tenant, opts) do
      {:ok, %{model: model, vector: vector}}
    end
  end

  @doc """
  Scales a vector to unit length.

  Stored vectors are normalised on the way in so the dot product in
  `FirstmatePort.Fleet.Document`'s `:similarity` is already cosine similarity.
  A zero vector is returned unchanged; there is no direction to preserve.
  """
  def unit(vector) when is_list(vector) do
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn value, acc -> acc + value * value end))

    if norm == 0.0 do
      vector
    else
      Enum.map(vector, &(&1 / norm))
    end
  end

  defp validate_parts(provider, _model) do
    if provider in providers() do
      :ok
    else
      {:error, "names a provider this build cannot reach; see docs/fleet-search.md"}
    end
  end

  defp configuration(tenant) do
    slug = Tenancy.slug(tenant)

    with {:ok, spec} <- ok_or(model(slug), :disabled),
         {:ok, api_key} <- ok_or(Credentials.secret(slug, @provider, @key), :missing_api_key) do
      {:ok, %{model: spec, api_key: api_key}}
    end
  end

  defp tenant_model(slug) do
    case Tenant.get_by_slug(slug, authorize?: false) do
      {:ok, %Tenant{embedding_model: spec}} -> present(spec)
      _ -> :error
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_value), do: :error

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp check_shape(vectors, texts) when length(vectors) == length(texts) do
    if Enum.all?(vectors, &(is_list(&1) and &1 != [])) do
      :ok
    else
      {:error, :empty_vector}
    end
  end

  defp check_shape(_vectors, _texts), do: {:error, :vector_count_mismatch}

  # A module implementing `FirstmatePort.Fleet.Embeddings.Client`, or - for a
  # test that only needs one canned answer - a three-argument function.
  defp invoke(client, model, texts, opts) when is_function(client, 3) do
    client.(model, texts, opts)
  end

  defp invoke(client, model, texts, opts), do: client.embed(model, texts, opts)

  # Tests pass `client:` directly rather than setting application environment,
  # which is what keeps them async.
  defp client(opts) do
    Keyword.get(opts, :client) ||
      Application.get_env(:firstmate_port, __MODULE__, [])[:client] ||
      FirstmatePort.Fleet.Embeddings.ReqLLMClient
  end

  defp opts_for_client(opts), do: Keyword.drop(opts, [:client])
end
