defmodule FirstmatePort.Jobs.TickTest do
  # async: false + shared sandbox: Ash runs generic actions in a spawned
  # process, which needs the shared checkout for the transaction wrapper.
  use FirstmatePort.DataCase, async: false

  alias FirstmatePort.Jobs.Tick

  # The AshOban scheduled workers run their target through Ash.ActionInput,
  # which only resolves generic actions. These tests mirror that path: with
  # the poll credentials unset the github run short-circuits before any HTTP
  # touch, so they prove the schedule targets resolve without side effects.
  test "github_poll schedule target resolves as a generic action" do
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_ORG")

    assert {:ok, :ok} =
             Tick
             |> Ash.ActionInput.new()
             |> Ash.ActionInput.for_action(:github_poll, %{})
             |> Ash.run_action()
  end

  test "retention schedule target resolves as a generic action" do
    assert {:ok, :ok} =
             Tick
             |> Ash.ActionInput.new()
             |> Ash.ActionInput.for_action(:retention, %{})
             |> Ash.run_action()
  end
end
