defmodule FirstmatePort.Test.AppConfig do
  @moduledoc """
  Temporarily override application configuration inside a test.

  `Application.get_env/2` followed by `Application.put_env/3` in `on_exit` is
  the obvious way to do this and it is wrong: a key that was never set reads
  back as `nil`, and putting `nil` back leaves the key *set to nil* rather than
  absent. Later tests then read `nil` where code expected a keyword list. This
  restores absence as absence.

  Tests using it must be `async: false` — application env is global.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Sets `:firstmate_port`'s `key` for the duration of the test."
  def put_env(key, value) do
    original = Application.fetch_env(:firstmate_port, key)
    Application.put_env(:firstmate_port, key, value)

    on_exit(fn ->
      case original do
        {:ok, previous} -> Application.put_env(:firstmate_port, key, previous)
        :error -> Application.delete_env(:firstmate_port, key)
      end
    end)

    :ok
  end
end
