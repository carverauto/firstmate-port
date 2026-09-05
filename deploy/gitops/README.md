# GitOps follow-up (do not apply from this worktree)

Attach the `firstmate` namespace to whatever Gateway your cluster uses for the
portal hostname. Proposed Argo Application YAML is `argocd-application.yaml`.

HTTPRoute for the portal lives in this repo (`k8s/httproute.yaml`) and defaults
to `firstmate.example.com`. Overlay the real hostname in GitOps.

Public Discord interactions (if enabled) use a separate hostname
(`interactions.example.com` in the sample manifests). Keep the portal hostname
off any public VIP.

Site-specific labels and hostnames (for example a LAN Gateway selector) belong
in `deploy/examples/` or the GitOps overlay, not as the only compiled-in
identity.
