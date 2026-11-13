# Pushing the telemetry work: branches and PRs

Local checklist, not part of any PR (the commands below stage by path, so this file is
never committed). Delete it when you are done.

Three branches, split by path, so each PR is small and reviewable:

| Branch | Contents | Base |
|---|---|---|
| `feature/cumulus-telemetry` | `cumulus/`: EVPN fix, SNMP, NVUE REST API step in the samples, role and vars | `main` |
| `feature/arista-telemetry` | `arista/`: gNMI role tag, vars, README | `main` |
| `feature/kubernetes-lab-cluster` (existing PR #3) | `kubernetes/` (snmp, bgp and gnmi plays, both dashboards) and the root `README.md` | already open |

Merge the Cumulus and Arista PRs first: the dashboards only have data once the switches are
configured.

## 0. Before you start (repo root)

```bash
git status --short      # should list only the files from this work (about 24)
git diff --stat         # skim it once
```

Nothing secret is staged. The Grafana admin and MinIO passwords live in `kubernetes/artifacts/`
(git-ignored). What is committed is the lab `monitor` password (`Fabric-Mon-ro1`) in
`kubernetes/group_vars/all.yml` and its SHA-512 hash in the Cumulus and Arista vars.

## 1. Cumulus branch

```bash
git switch -c feature/cumulus-telemetry feature/kubernetes-lab-cluster   # carries your uncommitted changes
git add cumulus
git commit -m "Cumulus: enable EVPN globally, add SNMP and NVUE REST API monitoring

- nv set evpn enable on (samples + overlay template)
- SNMPv2c read-only step in all 8 samples and the underlay role
- read-only NVUE API user + nginx enablement for BGP session monitoring

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -u origin feature/cumulus-telemetry
gh pr create --base main --title "Cumulus: EVPN fix, SNMP and NVUE REST API monitoring" \
  --body "Adds global EVPN enable, SNMPv2c and a read-only NVUE REST API user to the Cumulus samples and roles. Validated on the GNS3 lab (8 switches).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

## 2. Arista branch

```bash
git switch -c feature/arista-telemetry feature/kubernetes-lab-cluster    # remaining changes carry over
git add arista
git commit -m "Arista: enable gNMI telemetry with a read-only monitor user

New telemetry tag in the arista_base role (telemetry.j2), vars and README.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -u origin feature/arista-telemetry
gh pr create --base main --title "Arista: gNMI telemetry (role tag + monitor user)" \
  --body "Enables the OpenConfig gNMI server (6030, mgmt VRF) and a read-only user on all 6 vEOS switches via ansible-playbook site.yml --tags telemetry.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

## 3. Kubernetes work (updates PR #3)

```bash
git switch feature/kubernetes-lab-cluster
git add kubernetes README.md
git commit -m "Kubernetes: SNMP, BGP (NVUE API) and gNMI telemetry with Grafana dashboards

- --tags snmp, bgp and gnmi plays (snmp-exporter, json-exporter, gnmic)
- Cumulus VXLAN Fabric and Arista VXLAN Fabric dashboards (code, via sidecar ConfigMaps)
- README updates

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push
```

The push updates PR #3 by itself. Then fix its title and description so they no longer say
"cluster only":

```bash
gh pr edit 3 --title "Kubernetes lab cluster with monitoring and fabric telemetry" \
  --body "HA kubeadm cluster, MetalLB, Prometheus/Grafana/Mimir, plus SNMP, BGP and gNMI telemetry for the Cumulus and Arista fabrics with two Grafana dashboards.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

## 4. Check each step

```bash
git status --short       # after each commit: nothing you meant to include is left over
gh pr list               # the three PRs
gh pr view --web         # open the current branch's PR in the browser
```

## 5. After the PRs merge

```bash
git switch main && git pull
git branch -d feature/cumulus-telemetry feature/arista-telemetry feature/kubernetes-lab-cluster
git remote prune origin
```

## Shortcut: one PR

Skip steps 1 and 2 and run this on the current branch. Everything lands in PR #3, which is
quicker but mixes three vendors in one review:

```bash
git add -A -- . ':!PUSH-STEPS.md'
git commit -m "Fabric telemetry: Cumulus SNMP/REST API, Arista gNMI, Kubernetes exporters and dashboards"
git push
```
