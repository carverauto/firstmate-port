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

Do not commit `MODULE.bazel.lock` changes produced by partial builds or by
`bazel mod deps` on macOS: they prune the `rules_oci` block the publish
pipeline needs. That block is load-bearing even when its pins look stale.

## Browser assets

`//:portal_image` ships real CSS/JS. The chain is `//:css_bundle` (pinned
tailwindcss binary) + `//:js_bundle` (pinned esbuild binary, Hex `phoenix_*`
JS via `NODE_PATH`, colocated stub at `build/phoenix-colocated-index.js`) →
`//:static_undigested` (plus committed `priv/static` files) →
`//:static` (`phoenix_digest`, same rule serviceradar uses) → overlaid into
the release's `priv/` by `elixir_release(overlays = ...)` — the same
`mix assets.deploy` flow as the Dockerfile, minus Mix. `//:css_bundle` and
`//:js_bundle` outputs are byte-identical to `mix compile && mix assets.deploy`.

Local `mix assets.deploy` requires `mix compile` first: the
`:phoenix_live_view` compiler emits
`_build/$MIX_ENV/phoenix-colocated/<app>/index.js`, which esbuild resolves via
`NODE_PATH`. Deploy-before-compile fails with
`Could not resolve "phoenix-colocated/..."`. Never commit digest outputs;
`.gitignore` excludes `priv/static/assets`, `cache_manifest.json`, and
`<name>-<32hex>.<ext>[.gz]` siblings. If colocated hooks/JS are added under
`lib/`, revisit the stub (see its header).

## CI and OCI

`buildbuddy.yaml` is BazelCI: same self-hosted `workflows` pool and runner image as serviceradar. The **Publish OCI** action pushes `ghcr.io/<owner>/firstmate-port` and `fm-steer` via `//:portal_image_push` / `//:fm-steer_image_push`. GitHub Actions `.github/workflows/bazel.yml` builds Go targets; `.github/workflows/publish-oci.yml` is the same push from a runner. Write the BuildBuddy API key into gitignored `.bazelrc.remote` from a secret, never commit it. `--config=ci` belongs on a runner only.

```sh
# Publish (ghcr.io is the registry; the repository is always passed explicitly)
./tools/bazel run //:portal_image_push -- --repository ghcr.io/<owner>/firstmate-port --tag sha-$(git rev-parse --short HEAD)
```

