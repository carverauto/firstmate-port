defmodule FirstmatePortWeb.FleetSearchJourneyTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.FleetFixtures
  import Phoenix.LiveViewTest

  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Fleet.{Document, Embedder, Embeddings}
  alias FirstmatePort.Tenancy

  test "captain searches synchronized logs, opts into embeddings, and excludes failures", %{
    conn: conn
  } do
    tenant("search-journey")
    captain = human("search-journey")
    {robot, token} = agent_with_token("search-journey")
    progress_item(robot, %{title: "helm revision rolled back", body: "Deployment restored"})
    progress_item(robot, %{title: "roll failed", body: "Deployment failed"})
    api = fn -> build_conn() |> put_req_header("authorization", "Bearer " <> token) end
    sync = api.() |> post("/api/fleet/sync")
    assert %{"scanned" => 2, "written" => 2} = json_response(sync, 200)

    {:ok, jwt, _} = Guardian.encode_and_sign(captain)
    signed_in = conn |> init_test_session(%{}) |> put_session(:guardian_token, jwt)
    {:ok, search, _} = live(signed_in, "/search")
    search |> form("form[phx-submit=search]", %{"q" => "helm"}) |> render_submit()
    lexical_html = render_async(search)
    assert lexical_html =~ "helm revision rolled back"
    capture("search-lexical.html", lexical_html)

    {:ok, settings, _} = live(signed_in, "/settings/credentials")

    settings
    |> form("form[phx-submit=set_embedding_model]", %{"model" => "openai:text-embedding-3-small"})
    |> render_submit()

    assert render(settings) =~ "Save an embeddings/api_key credential"

    settings
    |> element("form[phx-change=select_slot]")
    |> render_change(%{"slot" => "embeddings/api_key"})

    settings |> form("#credential-form-0", %{"value" => "sk-journey-fixture"}) |> render_submit()
    settings_html = render(settings)
    assert settings_html =~ "On, using openai:text-embedding-3-small"
    refute settings_html =~ "sk-journey-fixture"
    capture("search-credentials.html", settings_html)

    previous = Application.get_env(:firstmate_port, Embeddings)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:firstmate_port, Embeddings, previous),
        else: Application.delete_env(:firstmate_port, Embeddings)
    end)

    client = fn _model, texts, opts ->
      assert opts[:api_key] == "sk-journey-fixture"
      {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)}
    end

    Application.put_env(:firstmate_port, Embeddings, client: client)
    assert {:ok, %{embedded: 2}} = Embedder.run("search-journey")
    assert {:ok, documents} = Document.list(Tenancy.opts(captain))
    assert Enum.all?(documents, & &1.embedded_at)

    query = "release reverted -failed"
    search |> form("form[phx-submit=search]", %{"q" => query}) |> render_submit()
    semantic_html = render_async(search)
    assert semantic_html =~ "helm revision rolled back"
    refute semantic_html =~ "roll failed"
    capture("search-semantic.html", semantic_html)
    response = api.() |> get("/api/fleet/search", %{"q" => query})
    assert %{"semantic" => %{"state" => "ready"}, "data" => [hit]} = json_response(response, 200)
    assert hit["title"] == "helm revision rolled back"
    assert hit["lexical_rank"] == nil
    assert hit["semantic_rank"] == 1
    capture("search-api.json", Jason.encode!(json_response(response, 200), pretty: true))
    capture("search-sync.json", sync.resp_body)
  end

  defp capture(name, content) do
    if directory = System.get_env("FLEET_TEST_EVIDENCE") do
      File.write!(Path.join(directory, name), content)
    end
  end
end
