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

`buildbuddy.yaml` is the BazelCI workflow (self-hosted pool, `--config=ci` on the runner only). GitHub Actions `.github/workflows/bazel.yml` builds Go targets; `.github/workflows/publish-oci.yml` pushes Harbor images via `//:portal_image_push`. Write the BuildBuddy API key into gitignored `.bazelrc.remote` from a secret, never commit it.

```sh
# Publish (Harbor is the internal registry; ghcr.io is a later public mirror)
./tools/bazel run //:portal_image_push -- --repository registry.example.com/firstmate/firstmate-port --tag sha-$(git rev-parse --short HEAD)
```

