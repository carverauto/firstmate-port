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
        *) exit 1 ;;
      esac
    elif [[ "$1" == create && "$2" == secret && "$3" == generic ]]; then
      if [[ "$4" == firstmate-cloak ]]; then
        printf '%s' "${5#--from-literal=key=}" > "$CLOAK_OUTPUT"
      fi
    else
      exit 1
    fi
    """)

    File.chmod!(kubectl, 0o755)
    {:ok, output: Path.join(tmp_dir, "cloak-key")}
  end

  defp bootstrap(tmp_dir, output, base, exists) do
    System.cmd("bash", ["deploy/bootstrap-secrets.sh"],
      env: [
        {"PATH", Path.expand(tmp_dir) <> ":" <> System.fetch_env!("PATH")},
        {"APP_SECRET_BASE", base},
        {"CLOAK_EXISTS", to_string(exists)},
        {"CLOAK_OUTPUT", Path.expand(output)}
      ],
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
end
