defmodule FirstmatePort.Fleet.EmbedderTest do
  use FirstmatePort.DataCase, async: true

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Credentials
  alias FirstmatePort.Fleet.{Document, Embedder, Sync}
  alias FirstmatePort.Portal.ProgressItem
  alias FirstmatePort.Tenancy

  @model "openai:text-embedding-3-small"

  setup do
    tenant("local")
    actor = agent("local")
    person = human("local")

    progress_item(actor, %{title: "helm revision rolled back"})
    {:ok, _} = Sync.run("local")

    {:ok, actor: actor, human: person}
  end

  defp configure(human, opts) do
    if spec = Keyword.get(opts, :model) do
      {:ok, tenant} = Tenant.get_by_slug("local", actor: human)
      {:ok, _} = Tenant.set_embedding_model(tenant, %{embedding_model: spec}, actor: human)
    end

    if key = Keyword.get(opts, :key) do
      {:ok, _} =
        Credentials.put(%{provider: "embeddings", key: "api_key", value: key},
          actor: human,
          tenant: "local"
        )
    end

    :ok
  end

  defp client(vector) do
    fn _model, texts, _opts -> {:ok, Enum.map(texts, fn _text -> vector end)} end
  end

  test "an unconfigured portal is not a failure" do
    assert {:ok, %{embedded: 0, state: :off}} = Embedder.run("local")
  end

  test "a model without a key reports that and embeds nothing", %{human: human} do
    :ok = configure(human, model: @model)

    assert {:ok, %{embedded: 0, state: :missing_api_key}} = Embedder.run("local")
  end

  test "documents are embedded and then left alone", %{human: human, actor: actor} do
    :ok = configure(human, model: @model, key: "sk-test")

    assert {:ok, %{embedded: 1, state: {:ready, @model}}} =
             Embedder.run("local", client: client([3.0, 4.0]))

    assert {:ok, [document]} = Document.list(Tenancy.opts(actor))
    assert document.embedding_model == @model
    assert document.embedding_dimensions == 2
    assert document.embedded_at

    assert {:ok, %{embedded: 0, state: :idle}} =
             Embedder.run("local", client: client([3.0, 4.0]))
  end

  test "the stored vector is unit length, so the dot product is cosine", %{
    human: human,
    actor: actor
  } do
    :ok = configure(human, model: @model, key: "sk-test")
    {:ok, _} = Embedder.run("local", client: client([3.0, 4.0]))

    {:ok, [%{id: id}]} = Document.list(Tenancy.opts(actor))
    {:ok, stored} = Ash.get(Document, id, Tenancy.opts(actor))

    assert stored.embedding == [0.6, 0.8]
  end

  test "changed text is re-embedded, and the old vector answers until then", %{
    human: human,
    actor: actor
  } do
    :ok = configure(human, model: @model, key: "sk-test")
    {:ok, _} = Embedder.run("local", client: client([1.0, 0.0]))

    {:ok, [item]} = ProgressItem.list(Tenancy.opts(actor))

    {:ok, _} =
      ProgressItem.touch(item, %{kind: :note, title: "helm rolled forward"}, Tenancy.opts(actor))

    {:ok, %{written: 1}} = Sync.run("local")

    {:ok, [document]} = Document.list(Tenancy.opts(actor))
    assert document.embedded_at, "the stale vector is kept, not dropped"

    assert {:ok, %{embedded: 1}} = Embedder.run("local", client: client([0.0, 1.0]))
    assert {:ok, %{embedded: 0, state: :idle}} = Embedder.run("local", client: client([0.0, 1.0]))
  end

  test "changing the model re-embeds everything", %{human: human} do
    :ok = configure(human, model: @model, key: "sk-test")
    {:ok, %{embedded: 1}} = Embedder.run("local", client: client([1.0, 0.0]))

    :ok = configure(human, model: "google:gemini-embedding-001")

    assert {:ok, %{embedded: 1, state: {:ready, "google:gemini-embedding-001"}}} =
             Embedder.run("local", client: client([1.0, 0.0]))
  end

  test "a provider failure is returned so the job retries", %{human: human} do
    :ok = configure(human, model: @model, key: "sk-test")

    client = fn _model, _texts, _opts -> {:error, :rate_limited} end

    assert {:error, :rate_limited} = Embedder.run("local", client: client)
  end

  test "batches are bounded", %{human: human, actor: actor} do
    :ok = configure(human, model: @model, key: "sk-test")
    for index <- 1..4, do: progress_item(actor, %{title: "note #{index}"})
    {:ok, _} = Sync.run("local")

    assert {:ok, %{embedded: 2}} = Embedder.run("local", batch: 2, client: client([1.0, 0.0]))
    assert {:ok, %{embedded: 2}} = Embedder.run("local", batch: 2, client: client([1.0, 0.0]))
  end
end
