defmodule FirstmatePort.Auth.VendorNeutralTest do
  @moduledoc """
  The portal speaks generic OIDC. A vendor name may appear only as one example
  issuer under deploy/examples, never as an adapter, process name, or default.
  """
  use ExUnit.Case, async: true

  @vendor "authentik"
  @root Path.expand("../../..", __DIR__)

  # Example overlays are allowed to name a real provider; that is their job.
  @allowed_dirs ["deploy/examples"]

  # This file names the vendor in order to look for it.
  @self "test/firstmate_port/auth/vendor_neutral_test.exs"

  test "no vendor-named process, module, or config in the OTP app" do
    offenders =
      repo_files(["lib", "config", "test"])
      |> Enum.reject(&(&1 == @self))
      |> Enum.filter(&contains_vendor?/1)

    assert offenders == [],
           """
           OIDC must be a generic abstraction, not a driver for one vendor.
           Vendor-named code found in: #{Enum.join(offenders, ", ")}
           """
  end

  test "no vendor-named default in shipped deploy manifests or env samples" do
    offenders =
      repo_files([".env.example", "k8s", "deploy", "docker-compose.yml"])
      |> Enum.reject(fn path -> Enum.any?(@allowed_dirs, &String.starts_with?(path, &1)) end)
      |> Enum.filter(&contains_vendor?/1)

    assert offenders == [],
           """
           Site-specific issuers belong in #{Enum.join(@allowed_dirs, ", ")}.
           Vendor-named defaults found in: #{Enum.join(offenders, ", ")}
           """
  end

  # Includes untracked-but-not-ignored files, so a newly added vendor-shaped
  # module is caught before it is ever staged.
  defp repo_files(paths) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard", "--" | paths]
    {out, 0} = System.cmd("git", args, cd: @root)

    out |> String.split("\n", trim: true) |> Enum.uniq()
  end

  defp contains_vendor?(path) do
    case File.read(Path.join(@root, path)) do
      {:ok, contents} -> String.contains?(String.downcase(contents), @vendor)
      _ -> false
    end
  end
end
