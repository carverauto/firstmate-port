defmodule FirstmatePort.Fleet.EmbeddingsTest do
  use FirstmatePort.DataCase, async: true

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Credentials
  alias FirstmatePort.Fleet.Embeddings

  @model "openai:text-embedding-3-small"

  setup do
    tenant("local")
    {:ok, human: human("local")}
  end

  defp choose_model(human, spec) do
    {:ok, tenant} = Tenant.get_by_slug("local", actor: human)
    Tenant.set_embedding_model(tenant, %{embedding_model: spec}, actor: human)
  end

  defp save_key(human, value) do
    Credentials.put(%{provider: "embeddings", key: "api_key", value: value},
      actor: human,
      tenant: "local"
    )
  end

  test "a fresh portal has embeddings off" do
    assert :off = Embeddings.state("local")
    assert :error = Embeddings.model("local")
  end

  test "a model without a key is not on yet", %{human: human} do
    {:ok, _} = choose_model(human, @model)
    assert :missing_api_key = Embeddings.state("local")
    assert {:error, :missing_api_key} = Embeddings.embed(["hello"], "local")
  end

  test "a model and a key together turn it on", %{human: human} do
    {:ok, _} = choose_model(human, @model)
    {:ok, _} = save_key(human, "sk-test")

    assert {:ready, @model} = Embeddings.state("local")
  end

  test "the tenant's choice wins over the deployment default", %{human: human} do
    assert :error = Embeddings.model("local")
    {:ok, _} = choose_model(human, "google:gemini-embedding-001")
    assert {:ok, "google:gemini-embedding-001"} = Embeddings.model("local")
  end

  test "clearing the choice falls back to the deployment default", %{human: human} do
    {:ok, _} = choose_model(human, @model)
    {:ok, _} = choose_model(human, "")

    assert :error = Embeddings.model("local")
  end

  test "an agent key cannot change which provider the fleet log is sent to" do
    robot = agent("local")
    {:ok, tenant} = Tenant.get_by_slug("local", actor: robot)

    assert {:error, %Ash.Error.Forbidden{}} =
             Tenant.set_embedding_model(tenant, %{embedding_model: @model}, actor: robot)
  end

  test "every catalogued model is one this build can actually embed with" do
    known = Embeddings.providers()

    for %{spec: spec} <- Embeddings.catalog() do
      assert :ok = Embeddings.validate_spec(spec), "#{spec} is offered but not usable"
      assert [provider, _model] = String.split(spec, ":", parts: 2)
      assert provider in known, "#{spec} names a provider this build cannot reach"
    end
  end

  test "checking a spec does not pay for the provider catalogue" do
    {micros, :ok} = :timer.tc(fn -> Embeddings.validate_spec(@model) end)
    assert micros < 100_000, "validation must stay off the slow catalogue path"
  end

  test "a malformed spec or an unreachable provider is refused at the form", %{human: human} do
    assert {:error, _} = Embeddings.validate_spec("not-a-spec")
    assert {:error, _} = Embeddings.validate_spec("nosuchprovider:text-embedding-3-small")
    assert {:error, _} = Embeddings.validate_spec(nil)

    {:ok, tenant} = Tenant.get_by_slug("local", actor: human)

    assert {:error, %Ash.Error.Invalid{}} =
             Tenant.set_embedding_model(tenant, %{embedding_model: "not-a-spec"}, actor: human)
  end

  test "a namespaced model from an aggregating provider is accepted" do
    assert :ok = Embeddings.validate_spec("openrouter:baai/bge-m3")
  end

  test "vectors come back unit length", %{human: human} do
    {:ok, _} = choose_model(human, @model)
    {:ok, _} = save_key(human, "sk-test")

    client = fn _model, _texts, _opts -> {:ok, [[3.0, 4.0]]} end

    assert {:ok, %{model: @model, vectors: [[0.6, 0.8]]}} =
             Embeddings.embed(["hello"], "local", client: client)
  end

  test "a zero vector is left alone rather than divided by zero" do
    assert Embeddings.unit([0.0, 0.0]) == [0.0, 0.0]
  end

  test "a provider that returns the wrong number of vectors is an error", %{human: human} do
    {:ok, _} = choose_model(human, @model)
    {:ok, _} = save_key(human, "sk-test")

    client = fn _model, _texts, _opts -> {:ok, [[1.0]]} end

    assert {:error, :vector_count_mismatch} =
             Embeddings.embed(["one", "two"], "local", client: client)
  end

  test "the shipped client sends the tenant's key and nothing else", %{human: human} do
    {:ok, _} = choose_model(human, @model)
    {:ok, _} = save_key(human, "sk-tenant-key")

    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "object" => "list",
          "model" => "text-embedding-3-small",
          "data" => [%{"object" => "embedding", "index" => 0, "embedding" => [3.0, 4.0]}],
          "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}
        })
      )
    end

    assert {:ok, %{vectors: [[0.6, 0.8]]}} =
             Embeddings.embed(["hello"], "local", req_http_options: [plug: plug])

    assert_received {:authorization, ["Bearer sk-tenant-key"]}
  end
end
