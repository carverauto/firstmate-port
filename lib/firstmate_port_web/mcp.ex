defmodule FirstmatePortWeb.Mcp do
  @moduledoc "AshAi MCP tool list for firstmate agents."

  def v1_tools do
    [
      :upload_diagram,
      :list_diagrams,
      :get_diagram,
      :post_progress,
      :list_progress,
      :post_roll,
      :list_rolls,
      :post_no_mistakes,
      :list_no_mistakes,
      :list_open_prs,
      :list_open_issues,
      :upsert_github_item,
      :assign_github_item,
      :search_fleet
    ]
  end

  def instructions do
    """
    Firstmate hub MCP. Upload Archify HTML, record progress (full https GitHub URLs only),
    farm01/demo rolls, and no-mistakes run events. Do not assemble GitHub URLs.
    List diagrams without html/png/svg payloads. no-mistakes findings stay on the LAN
    portal; Discord fan-out is generic (no snippets, no customer names).
    search_fleet searches everything already recorded here - PRs, issues, progress,
    rolls, no-mistakes runs, diagram titles - so prefer it over listing each kind.
    """
  end
end
