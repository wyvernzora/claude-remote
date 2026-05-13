# Reference manifests

Plain Kubernetes YAML reference for what a working deployment looks like. The author's actual repo is cdk8s-based; these exist so a coding agent can translate the shape directly.

Not exhaustive: no NetworkPolicy, no namespace, no horizontal hardening. Add those in the consuming repo.

## Pieces

- `configmap-mcp.yaml` — MCP config mounted at `/home/claude/.claude/.mcp.json` via `subPath`. Note: `subPath` mounts do not receive live ConfigMap updates; rolling the Deployment is required to pick up changes.
- `secret-oauth.example.yaml` — optional template for pre-seeding credentials via Secret. Default flow logs in inside the pod and skips the Secret entirely.
- `pvc.yaml` — two PVCs:
  - `claude-state` (2Gi) → `/home/claude` (whole home dir; holds `.claude/` and root-level `.claude.json`). claude auth login writes to both locations and remote-control reads from both; subdir-only mounts break the org-eligibility check on restart.
  - `claude-workspace` (10Gi) → `/workspace` (project files)
- `deployment.yaml` — single replica, `Recreate` strategy (no two-pod overlap), `envFrom: secretRef` for OAuth, `claude-health` exec liveness probe.

## Auth model

Remote-control requires a **full-scope OAuth login**. Long-lived tokens from `claude setup-token` (`CLAUDE_CODE_OAUTH_TOKEN`) are inference-only and will not work. Env-only auth (`CLAUDE_CODE_OAUTH_REFRESH_TOKEN` + `CLAUDE_CODE_OAUTH_SCOPES`) is also rejected — it works for inference but does not produce a "logged in" state. `claude auth login` writes more than just `.credentials.json` (also account/organization metadata under `~/.claude`), so the cleanest path is to log in inside the pod and let the state PVC capture all of it.

Default path — login in the running pod:

1. Apply manifests. First boot has no credentials → entrypoint falls into bootstrap mode: idle tmux session, pod stays Ready, logs print the recipe.
2. `kubectl exec -it deployment/claude-remote -- bash`
3. Inside: `claude auth login` (paste-back code flow), `claude auth status` to confirm, `exit`.
4. `kubectl delete pod -l app=claude-remote` — Recreate strategy spins a fresh pod; entrypoint finds credentials in the PVC and starts remote-control.

Subsequent restarts reuse the credentials. Access-token refreshes write back to the PVC in place.

Optional path — pre-seed credentials from a Secret:

`deployment.yaml` ships a commented-out `oauth-creds` Secret volume. Uncomment and create a Secret holding the credentials.json content:

```
kubectl create secret generic claude-oauth \
  --from-file=credentials.json=/path/to/.credentials.json
```

Entrypoint copies it onto the PVC on first boot. Note this only seeds `.credentials.json` — account/org metadata still has to be fetched on first run, so `claude auth login` in-pod remains the most reliable initial bootstrap.

To rotate either way: delete `.credentials.json` from the state PVC, restart the pod, do another `claude auth login` (or re-seed from updated Secret).

## Apply

```
kubectl apply -f deploy/pvc.yaml
kubectl apply -f deploy/configmap-mcp.yaml
kubectl apply -f deploy/deployment.yaml
# Pod boots in bootstrap mode (no credentials yet).
kubectl exec -it deployment/claude-remote -- bash
# inside: claude auth login; exit
kubectl delete pod -l app=claude-remote     # Recreate restarts with creds.
```

Edit before applying:
- `deploy/deployment.yaml` — replace `OWNER` and tag in the image reference.
- `deploy/configmap-mcp.yaml` — point at your real MCP server URL.

## Get the session URL

```
kubectl logs deployment/claude-remote | grep -E '^https://'
```

Re-grab after every pod restart — URL rotates until upstream `--session-id` lands.

## Volume layout note

Two PVCs because the image declares two `VOLUME`s (`/home/claude` and `/workspace`) and they have very different size/IO profiles. Don't collapse into one PVC unless you accept losing the separation.

## Refreshing or replacing credentials

When credentials expire/revoke, rerun the bootstrap pod (it overwrites `.credentials.json` in the PVC) and `kubectl rollout restart deployment/claude-remote`. No Secret rotation, no env var to bump.
