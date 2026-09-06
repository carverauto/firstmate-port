defmodule FirstmatePort.Portal.ProgressPaginationTest do
  @moduledoc """
  Pagination is server-side. The home preview asks for 20 rows and gets 20 rows;
  it never reads the whole table and slices in memory.
  """

  use FirstmatePort.DataCase, async: true

  import FirstmatePort.ProgressFixtures

  alias FirstmatePort.Portal.ProgressItem
  alias FirstmatePort.Tenancy

  setup do
    {:ok, agent_context("progress-pager")}
  end

  test "all reads exclude legacy imports without deleting them", %{opts: opts} do
    legacy = seed_legacy_item(opts, kind: :pr, title: "org import")
    crew = seed_item(opts, title: "crew work")

    assert {:ok, [item]} = ProgressItem.list(opts)
    assert item.id == crew.id
    assert {:ok, [_]} = ProgressItem.list_recent(opts)
    assert {:ok, [_]} = ProgressItem.list_paged(20, 0, opts)
    assert {:ok, [_]} = ProgressItem.list_for_stats(opts)
    assert {:ok, 1} = Ash.count(ProgressItem, opts)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             ProgressItem.get_by_url(legacy.url, opts)

    assert %{rows: [[1]]} =
             FirstmatePort.Repo.query!(
               "SELECT count(*) FROM progress_items WHERE id = $1",
               [legacy.id]
             )
  end

  test "list_recent caps at the home preview size, newest first", %{opts: opts} do
    seed_items(opts, 25)

    assert {:ok, items} = ProgressItem.list_recent(opts)
    assert length(items) == ProgressItem.preview_size()
    assert hd(items).title == title(25)
    assert List.last(items).title == title(16)
    assert Enum.map(items, & &1.title) == Enum.map(25..16//-1, &title/1)
  end

  test "the home preview is smaller than a /progress page", %{opts: _opts} do
    assert ProgressItem.preview_size() == 10
    assert ProgressItem.page_size() == 20
    assert ProgressItem.preview_size() < ProgressItem.page_size()
  end

  test "list_recent returns everything when fewer than a preview", %{opts: opts} do
    seed_items(opts, 3)

    assert {:ok, items} = ProgressItem.list_recent(opts)
    assert Enum.map(items, & &1.title) == [title(3), title(2), title(1)]
  end

  test "list_paged slices server-side with limit+offset", %{opts: opts} do
    seed_items(opts, 25)

    assert {:ok, page1} = ProgressItem.list_paged(20, 0, opts)
    assert {:ok, page2} = ProgressItem.list_paged(20, 20, opts)
    assert {:ok, total} = Ash.count(ProgressItem, opts)

    assert length(page1) == 20
    assert length(page2) == 5
    assert total == 25

    assert Enum.map(page1, & &1.title) == Enum.map(25..6//-1, &title/1)
    assert Enum.map(page2, & &1.title) == Enum.map(5..1//-1, &title/1)

    # Pages are disjoint and cover the whole table.
    assert (page1 ++ page2) |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 25
  end

  test "an offset past the end is an empty page, not an error", %{opts: opts} do
    seed_items(opts, 3)
    assert {:ok, []} = ProgressItem.list_paged(20, 40, opts)
  end

  test "list_paged rejects out-of-range limit and negative offset", %{opts: opts} do
    assert {:error, _} = ProgressItem.list_paged(ProgressItem.max_page_size() + 1, 0, opts)
    assert {:error, _} = ProgressItem.list_paged(0, 0, opts)
    assert {:error, _} = ProgressItem.list_paged(20, -1, opts)
  end

  test "for_stats is capped and newest first", %{opts: opts} do
    seed_items(opts, 5)

    assert {:ok, items} = ProgressItem.list_for_stats(opts)
    assert Enum.map(items, & &1.title) == Enum.map(5..1//-1, &title/1)
    assert length(items) <= ProgressItem.stats_cap()
  end

  test "count reflects the tenant wall", %{opts: opts, agent: agent} do
    seed_items(opts, 2)
    assert {:ok, 2} = Ash.count(ProgressItem, opts)

    other_opts = Tenancy.opts(%{agent | tenant_slug: "other"})
    assert {:ok, 0} = Ash.count(ProgressItem, other_opts)
    assert {:ok, []} = ProgressItem.list_recent(other_opts)
  end
end
