# GitOps follow-up (do not apply from this worktree)

Attach the `firstmate` namespace to whatever Gateway your cluster uses for the
portal hostname. Proposed Argo Application YAML is `argocd-application.yaml`.

HTTPRoute for the portal lives in this repo (`k8s/httproute.yaml`) and defaults
to `firstmate.example.com`. Overlay the real hostname in GitOps.

Public Discord interactions (if enabled) use a separate hostname on a separate
Gateway, matched path-only on `/interactions`. Keep the portal hostname off any
public VIP, and never expose the portal UI, `/mcp`, or NATS on the Discord
hostname.

Images come from ghcr.io (`ghcr.io/<owner>/firstmate-port`, tag `sha-<commit>`).
If the source repo is private, the namespace also needs a `ghcr-pull`
`docker-registry` secret made from a token with `read:packages`.

Site-specific labels and hostnames (for example a LAN Gateway selector) belong
in `deploy/examples/` or the GitOps overlay, not as the only compiled-in
identity. `deploy/examples/carverauto/` is a complete worked kustomize overlay:

```sh
kubectl apply -k deploy/examples/carverauto
```
