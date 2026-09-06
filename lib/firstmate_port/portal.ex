defmodule FirstmatePort.Portal do
  @moduledoc """
  Diagrams, progress, Kubernetes rolls, Docker builds, BuildBuddy
  invocations, and no-mistakes run records.
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
    tool :post_docker_build, FirstmatePort.Portal.DockerBuild, :record
    tool :list_docker_builds, FirstmatePort.Portal.DockerBuild, :read
    tool :post_buildbuddy_invocation, FirstmatePort.Portal.BuildBuddyInvocation, :record
    tool :list_buildbuddy_invocations, FirstmatePort.Portal.BuildBuddyInvocation, :read
    tool :post_no_mistakes, FirstmatePort.Portal.NoMistakesRun, :record
    tool :list_no_mistakes, FirstmatePort.Portal.NoMistakesRun, :read
    tool :list_open_prs, FirstmatePort.Portal.GithubItem, :open_prs
    tool :list_open_issues, FirstmatePort.Portal.GithubItem, :open_issues
    tool :upsert_github_item, FirstmatePort.Portal.GithubItem, :upsert
    tool :assign_github_item, FirstmatePort.Portal.GithubItem, :assign
  end

  resources do
    resource FirstmatePort.Portal.Diagram
    resource FirstmatePort.Portal.ProgressItem
    resource FirstmatePort.Portal.Roll
    resource FirstmatePort.Portal.DockerBuild
    resource FirstmatePort.Portal.BuildBuddyInvocation
    resource FirstmatePort.Portal.NoMistakesRun
    resource FirstmatePort.Portal.GithubItem
  end
end
