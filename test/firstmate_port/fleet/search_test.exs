defmodule FirstmatePort.Fleet.SearchTest do
  use FirstmatePort.DataCase, async: true

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Credentials
  alias FirstmatePort.Fleet.{Document, Search, Sync}
  alias FirstmatePort.Tenancy

  setup do
    tenant("local")
    {:ok, actor: agent("local"), human: human("local")}
  end

  describe "text search" do
    test "finds a record by a word in it", %{actor: actor} do
      progress_item(actor, %{title: "BuildBuddy invocation went missing"})
      progress_item(actor, %{title: "Unrelated note about lunch"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [%{document: %{title: title}}]}} =
               Search.run("buildbuddy", actor)

      assert title == "BuildBuddy invocation went missing"
    end

    test "ranks the closer match first", %{actor: actor} do
      progress_item(actor, %{title: "roll", body: "a passing mention of the roll job"})
      progress_item(actor, %{title: "roll roll roll", body: "roll job roll job roll"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [first, second]}} = Search.run("roll job", actor)
      assert first.document.title == "roll roll roll"
      assert second.document.title == "roll"
      assert first.score > second.score
    end

    test "search-box operators reach Postgres", %{actor: actor} do
      progress_item(actor, %{title: "roll succeeded on farm01"})
      progress_item(actor, %{title: "roll failed on farm01"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [%{document: %{title: "roll succeeded on farm01"}}]}} =
               Search.run("roll -failed", actor)

      assert {:ok, %{results: [%{document: %{title: "roll failed on farm01"}}]}} =
               Search.run(~s("roll failed"), actor)
    end

    test "an empty query returns nothing rather than everything", %{actor: actor} do
      progress_item(actor, %{title: "Something"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [], query: ""}} = Search.run("   ", actor)
    end

    test "one tenant cannot search another's log" do
      tenant("other")
      local = agent("local")
      other = agent("other")

      progress_item(local, %{title: "farm01 secret roll"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [_hit]}} = Search.run("farm01", local)
      assert {:ok, %{results: []}} = Search.run("farm01", other)
    end

    test "a signed-in human can search", %{actor: actor, human: human} do
      progress_item(actor, %{title: "visible to the crew"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [_hit]}} = Search.run("crew", human)
    end

    test "limit caps the results", %{actor: actor} do
      for index <- 1..5, do: progress_item(actor, %{title: "roll number #{index}"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: results}} = Search.run("roll", actor, limit: 2)
      assert length(results) == 2
    end
  end

  describe "semantic search" do
    setup %{actor: actor, human: human} do
      {:ok, tenant} = Tenant.get_by_slug("local", actor: human)

      {:ok, _} =
        Tenant.set_embedding_model(
          tenant,
          %{embedding_model: "openai:text-embedding-3-small"},
          actor: human
        )

      {:ok, _} =
        Credentials.put(%{provider: "embeddings", key: "api_key", value: "sk-test"},
          actor: human,
          tenant: "local"
        )

      {:ok, actor: actor}
    end

    test "finds a record that shares no words with the query", %{actor: actor} do
      progress_item(actor, %{title: "helm revision rolled back"})
      {:ok, _} = Sync.run("local")

      {:ok, [document]} = Document.list(Tenancy.opts(actor))

      {:ok, _} =
        Document.put_embedding(
          document,
          %{embedding: [1.0, 0.0, 0.0], model: "openai:text-embedding-3-small"},
          Tenancy.opts(actor)
        )

      client = fn _model, texts, _opts -> {:ok, Enum.map(texts, fn _ -> [1.0, 0.0, 0.0] end)} end

      assert {:ok, %{results: [result], semantic: {:ready, model}}} =
               Search.run("deployment reverted", actor, client: client)

      assert model == "openai:text-embedding-3-small"
      assert result.document.title == "helm revision rolled back"
      assert result.lexical_rank == nil
      assert result.semantic_rank == 1
    end

    test "semantic matches respect exclusions before the candidate limit", %{actor: actor} do
      progress_item(actor, %{title: "roll succeeded"})
      progress_item(actor, %{title: "roll failed"})
      {:ok, _} = Sync.run("local")
      {:ok, documents} = Document.list(Tenancy.opts(actor))

      for document <- documents do
        vector = if document.title == "roll failed", do: [1.0, 0.0], else: [0.6, 0.8]

        {:ok, _} =
          Document.put_embedding(
            document,
            %{embedding: vector, model: "openai:text-embedding-3-small"},
            Tenancy.opts(actor)
          )
      end

      client = fn _model, _texts, _opts -> {:ok, [[1.0, 0.0]]} end

      assert {:ok, %{results: [%{document: %{title: "roll succeeded"}}]}} =
               Search.run("roll -failed", actor, client: client)

      for query <- [
            "deployment reverted -failed",
            "deployment reverted -failing",
            ~s(deployment reverted -"roll failed")
          ] do
        assert {:ok,
                %{
                  results: [
                    %{document: %{title: "roll succeeded"}, lexical_rank: nil, semantic_rank: 1}
                  ]
                }} =
                 Search.run(query, actor, client: client, candidates: 1, limit: 1)
      end

      assert {:ok, %{results: [%{document: %{title: "roll failed"}}]}} =
               Search.run("deployment reverted -the", actor,
                 client: client,
                 candidates: 1,
                 limit: 1
               )
    end

    test "a record found by both passes outranks one found by either", %{actor: actor} do
      progress_item(actor, %{title: "roll one"})
      progress_item(actor, %{title: "roll two"})
      {:ok, _} = Sync.run("local")

      {:ok, documents} = Document.list(Tenancy.opts(actor))
      two = Enum.find(documents, &(&1.title == "roll two"))

      {:ok, _} =
        Document.put_embedding(
          two,
          %{embedding: [1.0, 0.0], model: "openai:text-embedding-3-small"},
          Tenancy.opts(actor)
        )

      client = fn _model, texts, _opts -> {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)} end

      assert {:ok, %{results: [first | _rest]}} = Search.run("roll", actor, client: client)
      assert first.document.title == "roll two"
      assert first.lexical_rank
      assert first.semantic_rank == 1
    end

    test "vectors of another width are never compared against", %{actor: actor} do
      progress_item(actor, %{title: "wide vector"})
      {:ok, _} = Sync.run("local")

      {:ok, [document]} = Document.list(Tenancy.opts(actor))

      {:ok, _} =
        Document.put_embedding(
          document,
          %{embedding: [1.0, 0.0, 0.0, 0.0], model: "openai:text-embedding-3-small"},
          Tenancy.opts(actor)
        )

      client = fn _model, texts, _opts -> {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)} end

      assert {:ok, %{results: []}} = Search.run("nothing lexical here", actor, client: client)
    end

    test "a provider failure is reported, not swallowed", %{actor: actor} do
      progress_item(actor, %{title: "roll three"})
      {:ok, _} = Sync.run("local")

      client = fn _model, _texts, _opts -> {:error, :rate_limited} end

      assert {:ok, %{results: [_hit], semantic: {:error, :rate_limited}}} =
               Search.run("roll", actor, client: client)
    end
  end

  describe "when embeddings are not configured" do
    test "search says so and still answers", %{actor: actor} do
      progress_item(actor, %{title: "roll four"})
      {:ok, _} = Sync.run("local")

      assert {:ok, %{results: [_hit], semantic: :off}} = Search.run("roll", actor)
    end
  end
end
