defmodule FirstmatePort.Portal.ProgressStatus do
  @moduledoc """
  The public statuses a fleet-log row can be in, in lifecycle order:

    * `:draft` — opened, not yet offered for review
    * `:in_progress` — being worked
    * `:ready_for_review` — waiting on a reviewer
    * `:ready_for_merge` — reviewed, waiting to land
    * `:stalled` — nobody is moving it
    * `:merged` — a pull request that landed
    * `:complete` — closed, finished, or a thing that already happened

  This vocabulary is closed. Crew and firstmate report into it; nothing else
  gets added without the captain saying so.

  GitHub is an enricher, not the catalogue, so it only ever maps onto the three
  states it can actually observe — merged, complete, in progress. Draft, ready
  for review, ready for merge, and stalled are judgements only the crew can
  report, and the poll never guesses them.

  Items whose log carries no `:status` event fall back to `default_for_kind/1`
  and the UI marks that as derived rather than reported.
  """

  @statuses [
    :draft,
    :in_progress,
    :ready_for_review,
    :ready_for_merge,
    :stalled,
    :merged,
    :complete
  ]

  @terminal [:merged, :complete]

  @doc "Every public status, in lifecycle order — the order charts and legends use."
  def all, do: @statuses

  @doc "The statuses that mean the work is finished."
  def terminal, do: @terminal

  @doc "True when reaching this status means the work is done."
  def terminal?(status), do: status in @terminal

  @doc "Human label for a status."
  def label(:draft), do: "draft"
  def label(:in_progress), do: "in progress"
  def label(:ready_for_review), do: "ready for review"
  def label(:ready_for_merge), do: "ready for merge"
  def label(:stalled), do: "stalled"
  def label(:merged), do: "merged"
  def label(:complete), do: "complete"
  def label(_), do: "unknown"

  @doc """
  Status implied by an item's kind when nothing has been appended to its log.

  A PR or issue we only ever recorded as open is in progress; an achievement or
  a note is a thing that already happened.
  """
  def default_for_kind(kind) when kind in [:pr, :issue], do: :in_progress
  def default_for_kind(kind) when kind in [:achievement, :note], do: :complete
  def default_for_kind(_), do: :in_progress

  @doc """
  Maps one GitHub search result onto a status.

  Only the three states GitHub can actually report:

    * a pull request with `merged_at` set -> `:merged`
    * a closed issue, or a closed unmerged pull request -> `:complete`
    * anything still open -> `:in_progress`

  Never the author, and never a crew judgement like draft or stalled.
  """
  def from_github(:pr, %{"pull_request" => %{"merged_at" => merged_at}})
      when is_binary(merged_at) and merged_at != "" do
    :merged
  end

  def from_github(_kind, %{"state" => "closed"}), do: :complete
  def from_github(_kind, %{"state" => "open"}), do: :in_progress
  def from_github(kind, _item), do: default_for_kind(kind)

  @doc """
  True when a GitHub-observed status may overwrite a crew-reported one.

  The poll knows when something merged or closed, and that always wins. It does
  not know the difference between "in progress", "draft", "ready for review",
  "ready for merge", and "stalled", so it must never drag a crew judgement back
  to plain in-progress.
  """
  def github_may_report?(_observed, nil), do: true
  def github_may_report?(observed, _current) when observed in @terminal, do: true
  def github_may_report?(:in_progress, current), do: terminal?(current)
  def github_may_report?(_observed, _current), do: false

  @doc "True when the value is one of the public statuses."
  def valid?(status), do: status in @statuses

  @doc """
  Parses only canonical status strings or enum atoms.
  """
  def parse(nil), do: :error
  def parse(status) when status in @statuses, do: {:ok, status}

  def parse(raw) when is_binary(raw) do
    Enum.find_value(@statuses, :error, &(Atom.to_string(&1) == raw && {:ok, &1}))
  end

  def parse(raw) when is_atom(raw), do: raw |> Atom.to_string() |> parse()
  def parse(_), do: :error
end

