defmodule FirstmatePort.Legal do
  @moduledoc """
  Operator identity shown on the public terms and privacy pages.

  The documents themselves are product copy and ship in the repo. Who is
  operating this particular instance is not: a hostname, a company name and a
  contact mailbox are deployment identity, and this repo keeps that out of
  compiled-in defaults (see `AGENTS.md`). So the pages read those three values
  from config, and the defaults describe a localhost instance run by nobody in
  particular.

      config :firstmate_port, :legal,
        operator: "Example Ltd",
        contact_email: "privacy@example.com",
        governing_law: "England and Wales"

  In a release these come from `LEGAL_OPERATOR`, `LEGAL_CONTACT_EMAIL` and
  `LEGAL_GOVERNING_LAW`. Set `LEGAL_CONTACT_EMAIL` before pointing Discord's
  Developer Portal at these URLs — a privacy policy with no route back to a
  human is not one.
  """

  @service_name "firstmate port"

  # The date the shipped text last changed. Bump it in the same commit that
  # edits terms.html.heex or privacy.html.heex; a policy whose "last updated"
  # line lies is worse than one with no date at all.
  @updated_on ~D[2026-09-05]

  @default_operator "the operator of this firstmate port instance"

  @doc "Name of the service, as the documents refer to it."
  @spec service_name() :: String.t()
  def service_name, do: @service_name

  @doc "The date the shipped policy text last changed."
  @spec updated_on() :: Date.t()
  def updated_on, do: @updated_on

  @doc "Who operates this instance, for the 'who is responsible' clauses."
  @spec operator() :: String.t()
  def operator do
    case config(:operator) do
      value when is_binary(value) -> value
      _ -> @default_operator
    end
  end

  @doc """
  Contact mailbox for legal and privacy requests, or `nil` when the operator
  has not configured one.
  """
  @spec contact_email() :: String.t() | nil
  def contact_email do
    case config(:contact_email) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          email -> email
        end

      _ ->
        nil
    end
  end

  @doc "Governing law for the terms, or `nil` when the operator has not set one."
  @spec governing_law() :: String.t() | nil
  def governing_law do
    case config(:governing_law) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          law -> law
        end

      _ ->
        nil
    end
  end

  defp config(key) do
    (Application.get_env(:firstmate_port, :legal) || [])
    |> Keyword.get(key)
  end
end
