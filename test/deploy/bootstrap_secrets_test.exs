defmodule FirstmatePort.BootstrapSecretsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    kubectl = Path.join(tmp_dir, "kubectl")

    File.write!(kubectl, """
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$1" == get && "$2" == ns ]]; then exit 0; fi
    if [[ "$1" == apply ]]; then cat >/dev/null; exit 0; fi
    shift 2
    if [[ "$1" == get && "$2" == secret ]]; then
      case "$3" in
        firstmate-db-credentials)
          if [[ "$*" == *jsonpath*username* ]]; then printf postgres | openssl base64 -A
          elif [[ "$*" == *jsonpath*password* ]]; then printf password | openssl base64 -A
          fi ;;
        firstmate-app)
          if [[ "$*" == *jsonpath* ]]; then printf '%s' "$APP_SECRET_BASE" | openssl base64 -A; fi ;;
        firstmate-cloak) [[ "$CLOAK_EXISTS" == true ]] ;;
        firstmate-agent|firstmate-nats) exit 0 ;;
        firstmate-admin)
          if [[ "${ADMIN_STATE:-missing}" == missing ]]; then exit 1; fi
          if [[ "$*" == *jsonpath*email* && "${ADMIN_STATE}" == complete ]]; then
            printf '%s' "${ADMIN_EMAIL_EXISTING:-admin@localhost}" | openssl base64 -A
          fi ;;
        *) exit 1 ;;
      esac
    elif [[ "$1" == create && "$2" == secret && "$3" == generic ]]; then
      if [[ "$4" == firstmate-cloak ]]; then
        printf '%s' "${5#--from-literal=key=}" > "$CLOAK_OUTPUT"
      fi
      if [[ -n "${KUBECTL_CALLS:-}" ]]; then printf 'create %s\n' "$*" >> "$KUBECTL_CALLS"; fi
    elif [[ "$1" == patch ]]; then
      if [[ -n "${KUBECTL_CALLS:-}" ]]; then printf 'patch %s\n' "$*" >> "$KUBECTL_CALLS"; fi
    else
      exit 1
    fi
    """)

    File.chmod!(kubectl, 0o755)
    {:ok, output: Path.join(tmp_dir, "cloak-key"), calls: Path.join(tmp_dir, "kubectl-calls")}
  end

  defp bootstrap(tmp_dir, output, base, exists) do
    bootstrap_with(tmp_dir, output, base, exists, [])
  end

  defp bootstrap_with(tmp_dir, output, base, exists, extra_env) do
    extra_keys = Enum.map(extra_env, &elem(&1, 0))

    env =
      [
        {"PATH", Path.expand(tmp_dir) <> ":" <> System.fetch_env!("PATH")},
        {"APP_SECRET_BASE", base},
        {"CLOAK_EXISTS", to_string(exists)},
        {"CLOAK_OUTPUT", Path.expand(output)},
        {"KUBECTL_CALLS", Path.join(tmp_dir, "kubectl-calls")},
        {"ADMIN_STATE", "missing"},
        {"ADMIN_EMAIL_EXISTING", "admin@localhost"}
      ]
      |> Enum.reject(fn {key, _} -> key in extra_keys end)
      |> Kernel.++(extra_env)

    System.cmd("bash", ["deploy/bootstrap-secrets.sh"],
      env: env,
      stderr_to_stdout: true
    )
  end

  test "provisioning preserves the key used before CLOAK_KEY was set", context do
    base = "existing-secret-key-base"
    assert {_, 0} = bootstrap(context.tmp_dir, context.output, base, false)
    expected = :crypto.hash(:sha256, "firstmate-port cloak v1:" <> base)
    assert Base.decode64!(File.read!(context.output)) == expected
  end

  test "an existing cloak secret is not replaced", context do
    File.write!(context.output, "existing-cloak-key")
    assert {_, 0} = bootstrap(context.tmp_dir, context.output, "base", true)
    assert File.read!(context.output) == "existing-cloak-key"
  end

  test "missing secret-key-base fails without provisioning a key", context do
    assert {_, 1} = bootstrap(context.tmp_dir, context.output, "", false)
    refute File.exists?(context.output)
  end

  test "a password-only admin secret gets its email backfilled, password untouched", context do
    assert {_, 0} =
             bootstrap_with(context.tmp_dir, context.output, "base", true,
               [{"ADMIN_STATE", "password-only"}]
             )

    calls = File.read!(context.calls)
    assert calls =~ "patch secret firstmate-admin"
    refute calls =~ "create secret generic firstmate-admin"

    assert [_, payload] = Regex.run(~r{/data/email","value":"([^"]+)"}, calls)
    assert Base.decode64!(payload) == "admin@localhost"
  end

  test "backfill honours ADMIN_EMAIL and leaves an existing email alone", context do
    assert {_, 0} =
             bootstrap_with(context.tmp_dir, context.output, "base", true,
               [{"ADMIN_STATE", "password-only"},
                {"ADMIN_EMAIL", "ops@example.test"}]
             )

    calls = File.read!(context.calls)
    assert [_, payload] = Regex.run(~r{/data/email","value":"([^"]+)"}, calls)
    assert Base.decode64!(payload) == "ops@example.test"

    File.rm!(context.calls)

    assert {out, 0} =
             bootstrap_with(context.tmp_dir, context.output, "base", true,
               [{"ADMIN_STATE", "complete"},
                {"ADMIN_EMAIL_EXISTING", "keeper@example.test"}]
             )

    assert out =~ "reusing firstmate-admin"
    # Only the pg-app dry-run create is logged; firstmate-admin is untouched.
    refute File.read!(context.calls) =~ "firstmate-admin"
  end
end
