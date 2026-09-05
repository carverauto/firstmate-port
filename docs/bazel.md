# Bazel

rules_elixir, rules_erlang, and BuildBuddy remote-exec patterns come from serviceradar, trimmed to this portal.

Always isolate local Bazel:

```sh
chmod +x tools/bazel
./tools/bazel build //:erlang_app
# equivalent:
bazel --output_base=/tmp/fm-fm-port/bazel build //:erlang_app
```

`--config=remote` is fine once `.bazelrc.remote` points at your BuildBuddy. Never `--config=ci` on a laptop.

Hex closure:

```sh
./tools/bazel run //third_party/hex:gen
./tools/bazel test //third_party/hex:gen_test
```

After `mix.lock` changes, regenerate `third_party/hex`.

## CI and OCI

`buildbuddy.yaml` is gitignored (site-specific BazelCI). GitHub Actions `.github/workflows/bazel.yml` builds Go targets; `.github/workflows/publish-oci.yml` pushes ghcr.io images via `//:portal_image_push`, logging in with the workflow `GITHUB_TOKEN`. Write the BuildBuddy API key into gitignored `.bazelrc.remote` from a secret, never commit it. `--config=ci` belongs on a runner only.

```sh
# Publish (ghcr.io is the registry; the repository is always passed explicitly)
./tools/bazel run //:portal_image_push -- --repository ghcr.io/<owner>/firstmate-port --tag sha-$(git rev-parse --short HEAD)
```

