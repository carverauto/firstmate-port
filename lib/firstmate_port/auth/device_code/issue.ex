defmodule FirstmatePort.Auth.DeviceCode.Issue do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    now = DateTime.utc_now()

    changeset
    |> Ash.Changeset.change_attribute(:device_code, random(32))
    |> Ash.Changeset.change_attribute(:user_code, user_code())
    |> Ash.Changeset.change_attribute(:expires_at, DateTime.add(now, 600, :second))
    |> Ash.Changeset.change_attribute(:interval, 5)
    |> Ash.Changeset.change_attribute(:status, :pending)
  end

  defp user_code do
    chars = ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    1..8
    |> Enum.map(fn _ -> Enum.random(chars) end)
    |> List.to_string()
    |> then(fn s -> String.slice(s, 0, 4) <> "-" <> String.slice(s, 4, 4) end)
  end

  defp random(n) do
    n |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
