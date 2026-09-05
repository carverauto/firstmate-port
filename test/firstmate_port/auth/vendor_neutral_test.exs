defmodule FirstmatePort.Auth.VendorNeutralTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Auth.OIDC

  @root Path.expand("../../..", __DIR__)

  test "configured providers use the generic worker identity" do
    cfg = [issuer: "https://idp.example.test", client_id: "portal", client_secret: "secret"]

    assert [%{id: :firstmate_oidc, start: {_, :start_link, [opts]}}] = OIDC.child_specs(cfg)
    assert opts.name == OIDC.provider_name()
    assert opts.issuer == "https://idp.example.test"
  end

  test "shipped runtimes enable local login without an issuer or allowlist" do
    [compose] = yaml("docker-compose.yml")
    compose_env = compose["services"]["portal"]["environment"]
    kubernetes_env = deployment_env("k8s/deployment.yaml")

    for env <- [compose_env, Map.new(kubernetes_env, fn {name, entry} -> {name, entry["value"]} end)] do
      assert env["LOCAL_AUTH"] == "true"
      assert is_nil(env["OIDC_ISSUER"])
      assert is_nil(env["OIDC_DISCOVERY_URL"])
      assert is_nil(env["ALLOWED_EMAIL_DOMAIN"])
    end

    for {name, key} <- [{"BOOTSTRAP_ADMIN_EMAIL", "email"}, {"BOOTSTRAP_ADMIN_PASSWORD", "password"}] do
      ref = kubernetes_env[name]["valueFrom"]["secretKeyRef"]
      assert ref["name"] == "firstmate-admin"
      assert ref["key"] == key
      refute Map.get(ref, "optional", false)
    end
  end

  test "the site overlay preserves local bootstrap login" do
    env =
      Map.merge(
        deployment_env("k8s/deployment.yaml"),
        deployment_env("deploy/examples/carverauto/deployment-patch.yaml")
      )

    assert env["LOCAL_AUTH"]["value"] == "true"
  end

  defp deployment_env(path) do
    deployment = Enum.find(yaml(path), &(&1["kind"] == "Deployment"))
    hub = Enum.find(deployment["spec"]["template"]["spec"]["containers"], &(&1["name"] == "hub"))
    Map.new(hub["env"], &{&1["name"], &1})
  end

  defp yaml(path), do: YamlElixir.read_all_from_file!(Path.join(@root, path))
end
