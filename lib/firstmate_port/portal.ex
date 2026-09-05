defmodule FirstmatePort.Portal do
  @moduledoc """
  Diagrams, progress, farm01/demo rolls, and no-mistakes run records.
  """

  use Ash.Domain,
    otp_app: :firstmate_port,
    extensions: [AshPaperTrail.Domain, AshAi]

  paper_trail do
    include_versions?(true)
  end

  tools do
    tool :upload_diagram, FirstmatePort.Portal.Diagram, :upload
    tool :list_diagrams, FirstmatePort.Portal.Diagram, :index
    tool :get_diagram, FirstmatePort.Portal.Diagram, :by_id
    tool :post_progress, FirstmatePort.Portal.ProgressItem, :record
    tool :list_progress, FirstmatePort.Portal.ProgressItem, :read
    tool :post_roll, FirstmatePort.Portal.Roll, :record
    tool :list_rolls, FirstmatePort.Portal.Roll, :read
    tool :post_no_mistakes, FirstmatePort.Portal.NoMistakesRun, :record
    tool :list_no_mistakes, FirstmatePort.Portal.NoMistakesRun, :read
    tool :record_usage, FirstmatePort.Portal.UsageAccount, :record
    tool :list_usage, FirstmatePort.Portal.UsageAccount, :read
    tool :record_usage_snapshot, FirstmatePort.Portal.UsageSnapshot, :record
    tool :list_usage_snapshots, FirstmatePort.Portal.UsageSnapshot, :by_account
    tool :list_open_prs, FirstmatePort.Portal.GithubItem, :open_prs
    tool :list_open_issues, FirstmatePort.Portal.GithubItem, :open_issues
    tool :upsert_github_item, FirstmatePort.Portal.GithubItem, :upsert
    tool :assign_github_item, FirstmatePort.Portal.GithubItem, :assign
  end

  resources do
    resource FirstmatePort.Portal.Diagram
    resource FirstmatePort.Portal.ProgressItem
    resource FirstmatePort.Portal.Roll
    resource FirstmatePort.Portal.NoMistakesRun
    resource FirstmatePort.Portal.GithubItem
    resource FirstmatePort.Portal.UsageAccount
    resource FirstmatePort.Portal.UsageSnapshot
  end
end
