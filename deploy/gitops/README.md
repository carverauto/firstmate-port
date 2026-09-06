# GitOps follow-up (do not apply from this worktree)

Attach the `firstmate` namespace to whatever Gateway your cluster uses for the
portal hostname. Proposed Argo Application YAML is `argocd-application.yaml`.

HTTPRoute for the portal lives in this repo (`k8s/httproute.yaml`) and defaults
to `firstmate.example.com`. Overlay the real hostname in GitOps.

For the interactions hostname’s path confinement and proxy TLS requirements,
see [Discord inbound](../../docs/credentials.md#publishing-the-interactions-hostname).
For the portal’s separate public-access policy, see
[Security](../../docs/security.md#public-access).

Images come from ghcr.io (`ghcr.io/<owner>/firstmate-port`, tag `sha-<commit>`).
If the source repo is private, the namespace also needs a `ghcr-io-cred`
`docker-registry` secret made from a token with `read:packages`.

Site-specific labels and hostnames (for example a LAN Gateway selector) belong
in `deploy/examples/` or the GitOps overlay, not as the only compiled-in
identity. `deploy/examples/carverauto/` is a complete worked kustomize overlay:

```sh
kubectl apply -k deploy/examples/carverauto
```
