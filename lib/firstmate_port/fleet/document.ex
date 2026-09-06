defmodule FirstmatePort.Fleet.Document do
  @moduledoc """
  One fleet-log record, projected into JSON and indexed for search.

  A document is addressed by its origin - `source` plus the `source_id` of the
  row it was projected from - so re-running `FirstmatePort.Fleet.Sync` updates
  the same row instead of piling up duplicates. `content_hash` covers the JSON
  and the flattened text, which is how a sync knows a record changed and how the
  embedder knows a vector went stale.

  ## Two indexes over the same text

  `search_text` is indexed twice. Postgres builds a `tsvector` from it through a
  GIN expression index (see `custom_statements` below), which is what
  `:search` queries; that index needs no extension and is always present.
  `embedding` holds an optional vector for the same text, written by
  `FirstmatePort.Fleet.Embedder` only when an operator has configured a model.

  Embeddings are stored unit-normalised, so the dot product in `:similarity`
  *is* cosine similarity and `:nearest` can order by it directly. That is a
  sequential scan with a per-row dot product: correct on any Postgres, and
  right-sized for a fleet log. It is not an approximate-nearest-neighbour index,
  and `docs/fleet-search.md` records where that ceiling is.

  `embedding` is deliberately not `public?`. A search result carrying a
  thousand floats would be useless to an MCP client and expensive to serialize,
  so it is never selected by the read actions below.
  """

  import Ash.Expr

  use Ash.Resource,
    otp_app: :firstmate_port,
    domain: FirstmatePort.Fleet,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @sources [:github_item, :progress_item, :roll, :no_mistakes_run, :diagram]

  # Everything a caller needs to render or rank a hit. `search_text` and
  # `embedding` are the two big columns and are left out on purpose.
  @summary_select [
    :id,
    :tenant_slug,
    :source,
    :source_id,
    :title,
    :url,
    :body,
    :document,
    :occurred_at,
    :content_hash,
    :embedding_model,
    :embedded_at,
    :inserted_at,
    :updated_at
  ]

  postgres do
    table "fleet_documents"
    repo FirstmatePort.Repo

    custom_statements do
      # An expression index rather than a stored tsvector column: the text is
      # already in `search_text`, and Ash's migration generator has no way to
      # describe a generated column.
      statement :fleet_documents_search_gin do
        up """
        CREATE INDEX fleet_documents_search_gin
          ON fleet_documents
          USING GIN (to_tsvector('english', search_text))
        """

        down "DROP INDEX IF EXISTS fleet_documents_search_gin"
      end
    end
  end

  code_interface do
    define :list, action: :read

    define :get_by_source,
      action: :by_source,
      args: [:source, :source_id],
      not_found_error?: false

    define :search, action: :search, args: [:query]
    define :nearest, action: :nearest, args: [:embedding, :model]
    define :needs_embedding, action: :needs_embedding, args: [:model]
    define :upsert, action: :upsert
    define :put_embedding, action: :put_embedding
  end

  actions do
    defaults [:read, :destroy]

    read :by_source do
      get? true
      argument :source, :atom, allow_nil?: false
      argument :source_id, :string, allow_nil?: false
      filter expr(source == ^arg(:source) and source_id == ^arg(:source_id))
    end

    action :search_fleet, :map do
      description "Search the fleet log by words and optional embeddings, with ranking and semantic status."

      argument :query, :string, allow_nil?: false
      argument :limit, :integer, default: 25, constraints: [min: 1, max: 100]

      run fn input, context ->
        with {:ok, result} <-
               FirstmatePort.Fleet.Search.run(input.arguments.query, context.actor,
                 limit: input.arguments.limit
               ) do
          {:ok, FirstmatePort.Fleet.Search.response(result)}
        end
      end
    end

    read :search do
      description """
      Full-text search over the fleet log, best match first.

      `query` is parsed by Postgres' `websearch_to_tsquery`, so quoted phrases
      and `-excluded` words work the way they do in a search box.
      """

      argument :query, :string, allow_nil?: false
      argument :limit, :integer, default: 50

      prepare FirstmatePort.Fleet.Preparations.LexicalSearch
    end

    read :nearest do
      description "Documents whose stored vector is closest to `embedding`, nearest first."

      argument :embedding, {:array, :float}, allow_nil?: false
      argument :model, :string, allow_nil?: false
      argument :limit, :integer, default: 50

      prepare FirstmatePort.Fleet.Preparations.VectorSearch
    end

    read :needs_embedding do
      description """
      Documents with no vector, a vector for different text, or a vector from a
      different model. Oldest change first, so a backfill makes progress.
      """

      argument :model, :string, allow_nil?: false
      argument :limit, :integer, default: 32

      prepare FirstmatePort.Fleet.Preparations.NeedsEmbedding
    end

    create :upsert do
      primary? true
      upsert? true
      upsert_identity :unique_source

      # The embedding columns are absent on purpose: a sync must not drop a
      # vector it has no way to recompute. `:needs_embedding` compares
      # `embedded_hash` with `content_hash`, so changed text is re-embedded on
      # the next backfill while the old vector keeps answering searches.
      upsert_fields [
        :title,
        :url,
        :body,
        :document,
        :search_text,
        :content_hash,
        :occurred_at
      ]

      accept [
        :source,
        :source_id,
        :title,
        :url,
        :body,
        :document,
        :search_text,
        :content_hash,
        :occurred_at
      ]
    end

    update :put_embedding do
      description "Stores a unit-normalised vector for the text `content_hash` covers."

      require_atomic? false

      argument :embedding, {:array, :float}, allow_nil?: false
      argument :model, :string, allow_nil?: false

      change FirstmatePort.Fleet.Changes.PutEmbedding
    end
  end

  policies do
    policy action(:search_fleet) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action_type([:create, :update, :destroy]) do
      # The projection is written by the sync and embedding jobs, never by a
      # person typing into the portal.
      authorize_if expr(^actor(:role) == :agent)
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_slug
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_slug, :string do
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      description "Which portal resource the record was projected from."
      constraints one_of: @sources
    end

    attribute :source_id, :string do
      allow_nil? false
      public? true
      description "Primary key of the row in that resource."
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :url, :string do
      default ""
      allow_nil? false
      public? true
      description "Copied from the record, never assembled."
      constraints allow_empty?: true
    end

    attribute :body, :string do
      default ""
      allow_nil? false
      public? true
      constraints allow_empty?: true
    end

    attribute :document, :map do
      default %{}
      allow_nil? false
      public? true
      description "The record as JSON. This is what a search result quotes from."
    end

    attribute :search_text, :string do
      default ""
      allow_nil? false
      public? false

      description "Flattened text behind both indexes. Truncated; see FirstmatePort.Fleet.Projection."

      constraints allow_empty?: true
    end

    attribute :content_hash, :string do
      default ""
      allow_nil? false
      public? true
      description "Digest of the JSON and the flattened text."
      constraints allow_empty?: true
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record happened, for recency ties and backfill order."
    end

    attribute :embedding, {:array, :float} do
      public? false
      description "Unit-normalised vector for search_text, or nil when embeddings are off."
    end

    attribute :embedding_model, :string do
      default ""
      allow_nil? false
      public? true
      description "Model spec that produced the vector, e.g. `provider:model`."
      constraints allow_empty?: true
    end

    attribute :embedding_dimensions, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :embedded_hash, :string do
      default ""
      allow_nil? false
      public? false
      description "content_hash at the time the vector was written."
      constraints allow_empty?: true
    end

    attribute :embedded_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  calculations do
    calculate :lexical_rank, :float do
      description "Postgres cover-density rank for one query. Higher is a better match."
      argument :query, :string, allow_nil?: false

      calculation expr(
                    fragment(
                      "ts_rank_cd(to_tsvector('english', ?), websearch_to_tsquery('english', ?), 32)",
                      search_text,
                      ^arg(:query)
                    )
                  )
    end

    calculate :similarity, :float do
      description """
      Dot product of the stored vector with the query vector. Both are unit
      length, so this is cosine similarity in [-1, 1].
      """

      argument :embedding, {:array, :float}, allow_nil?: false

      calculation expr(
                    fragment(
                      "(SELECT COALESCE(SUM(pair.stored * pair.query), 0.0) FROM unnest(?, ?::float8[]) AS pair(stored, query))",
                      embedding,
                      ^arg(:embedding)
                    )
                  )
    end
  end

  identities do
    identity :unique_source, [:tenant_slug, :source, :source_id]
  end

  @doc "The columns the search actions select. Excludes `search_text` and `embedding`."
  def summary_select, do: @summary_select

  @doc "Every source a document can be projected from."
  def sources, do: @sources
end
