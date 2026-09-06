defmodule FirstmatePort.Fleet.McpSearchTest do
  use FirstmatePort.DataCase, async: false

  import FirstmatePort.FleetFixtures

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Credentials
  alias FirstmatePort.Fleet
  alias FirstmatePort.Fleet.{Document, Embeddings, Sync}
  alias FirstmatePort.Tenancy

  @model "openai:text-embedding-3-small"

  setup do
    tenant("local")
    tenant("other")
    captain = human("local")
    robot = agent("local")
    previous = Application.get_env(:firstmate_port, Embeddings)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:firstmate_port, Embeddings)
      else
        Application.put_env(:firstmate_port, Embeddings, previous)
      end
    end)

    {:ok, tenant} = Tenant.get_by_slug("local", actor: captain)
    {:ok, _} = Tenant.set_embedding_model(tenant, %{embedding_model: @model}, actor: captain)

    {:ok, _} =
      Credentials.put(
        %{provider: "embeddings", key: "api_key", value: "sk-local"},
        Tenancy.opts(captain)
      )

    progress_item(robot, %{title: "helm revision rolled back"})
    {:ok, _} = Sync.run("local")
    {:ok, [document]} = Document.list(Tenancy.opts(robot))

    {:ok, _} =
      Document.put_embedding(
        document,
        %{embedding: [1.0, 0.0], model: @model},
        Tenancy.opts(robot)
      )

    test_pid = self()

    client = fn model, texts, opts ->
      send(test_pid, {:embedded_query, model, texts, opts[:api_key]})
      {:ok, [[1.0, 0.0]]}
    end

    Application.put_env(:firstmate_port, Embeddings, client: client)
    {:ok, captain: captain, other: human("other")}
  end

  test "the registered MCP tool returns semantic-only matches and status", %{captain: captain} do
    assert {:ok, result} =
             call_tool(%{"query" => "deployment reverted", "limit" => 1}, captain)

    assert %{
             query: "deployment reverted",
             semantic: %{state: "ready", model: @model},
             data: [
               %{
                 title: "helm revision rolled back",
                 lexical_rank: nil,
                 semantic_rank: 1,
                 score: score
               } = hit
             ]
           } = result

    assert score > 0
    refute Map.has_key?(hit, :embedding)
    refute Map.has_key?(hit, :search_text)
    assert_received {:embedded_query, @model, ["deployment reverted"], "sk-local"}
    assert {:ok, _json} = Jason.encode(result)
  end

  test "the tool uses the authenticated tenant", %{other: other} do
    assert {:ok, %{semantic: %{state: "off"}, data: []}} =
             call_tool(%{"query" => "helm"}, other)

    refute_received {:embedded_query, _, _, _}
  end

  test "the tool refuses an anonymous caller" do
    assert {:error, _} = call_tool(%{"query" => "helm"}, nil)
    refute_received {:embedded_query, _, _, _}
  end

  defp call_tool(arguments, actor) do
    tool = Enum.find(AshAi.Info.tools(Fleet), &(&1.name == :search_fleet))

    tool.resource
    |> Ash.ActionInput.for_action(tool.action, arguments, Tenancy.opts(actor))
    |> Ash.run_action()
  end
end
