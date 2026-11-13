# Arista EOS EVPN VXLAN Fabric

2 spines, 2 leafs and 2 border leafs on Arista EOS: numbered eBGP underlay,
eBGP EVPN overlay through the spines, symmetric IRB with a distributed anycast
gateway in vrf `PROD`. The `*_config.txt` files are the captured running configs
the variables were built from.

## Layout

```
arista/
├── ansible.cfg
├── site.yml                 # push config to the switches
├── render.yml               # render config to build/<host>/ - no device access
├── vault.yml.example        # template for group_vars/all/vault.yml
├── inventory/hosts.yml      # switches, mgmt IPs, groups
├── group_vars/
│   ├── all/vars.yml         # fabric-wide: VNIs, VRF, anycast MAC, NTP, ASNs
│   ├── spine.yml
│   ├── leaf.yml             # also applies to border leafs
│   └── border_leaf.yml
├── host_vars/<host>.yml     # per switch: ASN, router-id, VTEP, uplinks, host ports, WAN
└── roles/
    ├── arista_base/         # hostname, Management1, NTP
    ├── arista_underlay/     # loopbacks, p2p links, underlay + EVPN BGP
    ├── arista_overlay/      # VLANs, SVIs, Vxlan1, MAC-VRFs, IP-VRF (leafs)
    └── arista_border_leaf/  # WAN links + VRF-lite eBGP (border leafs)
```

## Common changes

| Change | Edit |
|---|---|
| New tenant VLAN / L2 VNI | add an entry to `vni_mappings` in `group_vars/all/vars.yml` |
| New host port | add to `host_ports` in that leaf's `host_vars` |
| New leaf | add it to `inventory/hosts.yml` and create `host_vars/<name>.yml` with `router_asn`, `router_id`, `vtep_ip`, `uplinks` - the spines pick up their side of the links automatically |
| WAN peering | fill in `wan_uplinks` in the border leaf's `host_vars` |

## One-time setup

Run from the repo root.

```bash
make venv                                       # creates .venv with ansible, arista.eos, paramiko
source .venv/bin/activate                       # needed if you call ansible-playbook directly

cd arista
cp vault.yml.example group_vars/all/vault.yml   # set the switch admin password
ansible-vault encrypt group_vars/all/vault.yml
echo '<vault-password>' > ~/.ansible/arista_vault_pass && chmod 600 ~/.ansible/arista_vault_pass
```

> Always use the venv's Ansible. The system `/usr/bin/ansible-playbook` has no
> paramiko and fails with `paramiko is not installed`. Either activate `.venv`
> or use the Makefile targets, which always call `.venv/bin/ansible-playbook`.

## Making a change and pushing it

**1. Check out a new branch** (repo root)

```bash
git switch main && git pull --ff-only origin main     # start from the latest main
git switch -c feature/arista-add-vlan30               # new branch (git checkout -b works too)
git branch --show-current                             # confirm you are not on main

# or in one step:
make branch BRANCH=feature/arista-add-vlan30
```

Branch names: `feature/arista-<what>` for new config, `fix/arista-<what>` for
corrections, `chore/arista-<what>` for docs and tooling.

**2. Edit the variables, not the templates.** See [Common changes](#common-changes).
Example: a new DB VLAN in `group_vars/all/vars.yml`:

```yaml
vni_mappings:
  ...
  - vlan: 30
    vni: 10030
    name: DB
    anycast_gw_ip: 10.10.30.254/24
```

Only edit `roles/*/templates/*.j2` when you need EOS commands the templates
do not produce yet.

**3. Render locally and review** - no switch access

```bash
cd arista
ansible-playbook render.yml          # or: make run VENDOR=arista PLAYBOOK=render.yml
cat build/arista-lf-1/30-overlay.cfg
```

**4. Dry-run against the switches** - shows the exact EOS diff, changes nothing

```bash
ansible-playbook site.yml --check --diff                        # all switches
ansible-playbook site.yml --check --diff --limit arista-lf-1    # one switch
# or from the repo root:
make check VENDOR=arista ARGS="--limit arista-lf-1"
```

Lines with `+` are added and lines with `-` are replaced. If the diff shows
something you did not expect, fix the vars and repeat from step 3.

**5. Push - one switch first, then the rest**

```bash
ansible-playbook site.yml --limit arista-lf-1    # canary
# verify (step 6), then:
ansible-playbook site.yml
# or from the repo root:
make run VENDOR=arista ARGS="--limit arista-lf-1"
make run VENDOR=arista
```

Useful limits: `--limit spine`, `--limit leaf` (includes the border leafs),
`--limit border_leaf`. The config is saved to startup-config only when
something changed.

**Pushing one section only.** Combine a tag with a limit to push one part of
the config instead of the whole of `site.yml`:

| Tag | Pushes |
|---|---|
| `ntp` | NTP servers (`ntp_servers`) |
| `base` | hostname, Management1, mgmt default route, NTP |
| `underlay` | loopbacks, spine links, underlay + EVPN BGP |
| `overlay` | VLANs, SVIs, Vxlan1, MAC-VRFs, VRF PROD |
| `border` | WAN links + VRF-lite eBGP |

Example: change `ntp_servers` in `group_vars/all/vars.yml`, then

```bash
ansible-playbook site.yml --tags ntp --limit leaf --check --diff   # preview
ansible-playbook site.yml --tags ntp --limit leaf                  # push
# or from the repo root:
make run VENDOR=arista ARGS="--tags ntp --limit leaf"
```

`ansible-playbook site.yml --list-tasks --tags ntp` shows what a tag selects.
Adding a server never removes an old one. To remove one, use `eos_cleanup_global`
with `--tags cleanup` (step 7).

**One-off command without a playbook.** For a quick single line that should
not live in the vars (e.g. a temporary test), send it ad hoc:

```bash
ansible leaf -m arista.eos.eos_config -a "lines='ntp server vrf mgmt 216.40.34.37' save_when=modified" --check --diff   # preview
ansible leaf -m arista.eos.eos_config -a "lines='ntp server vrf mgmt 216.40.34.37' save_when=modified"                  # push
ansible leaf -m arista.eos.eos_command -a "commands='show running-config | include ntp'"                              # verify
```

Use this only for temporary changes. The vars do not know about the line, so
`render.yml` won't show it and the switch no longer matches `vars.yml`. For
anything permanent, edit `ntp_servers` and use `--tags ntp`.

**6. Verify on the switch**

```
show bgp evpn summary                    ! EVPN sessions to both spines Estab
show ip bgp summary                      ! underlay sessions to both spines Estab
show vxlan vni                           ! L2 VNIs 100x0 + L3 VNI 50000 -> PROD
show ip route vrf PROD                   ! remote subnets/hosts via VTEP 10.255.1.x
show ip virtual-router                   ! anycast GW up with the shared MAC
```

Run the dry run again. It should report `changed=0`, which means the switch
matches the vars.

**7. Removing config.** `eos_config` only adds or replaces lines. It never
removes a line because it was deleted from the vars. To remove config, put the
`no ...` commands in `eos_cleanup_global` / `eos_cleanup_bgp` (group_vars/leaf.yml
or the host's host_vars) and run:

```bash
ansible-playbook site.yml --tags cleanup --check --diff   # preview
ansible-playbook site.yml --tags cleanup
```

Empty the list again afterwards so the same `no` commands are not re-sent.

**8. Refresh the captured configs** - keep `*_config.txt` matching the
switches

```bash
ssh admin@<mgmt-ip> 'show running-config' > arista-lf-1_config.txt
```

**9. Check in: commit, push and open a PR** (repo root)

```bash
git status -sb                                        # what changed
git diff                                              # review before staging
git add arista/ requirements.txt                      # stage only what belongs to this change
git commit -m "Add DB VLAN 30 / VNI 10030 to Arista leafs"
git push -u origin feature/arista-add-vlan30          # -u only needed the first time
gh pr create --base main --fill                       # open the pull request

# or with the Makefile (stages everything with git add -A):
make commit MSG="Add DB VLAN 30 / VNI 10030 to Arista leafs"
make pr
```

`make push` refuses to push `main`, so changes always go through a branch and a PR.

Do not commit `group_vars/all/vault.yml` unless it is encrypted (the first line
must be `$ANSIBLE_VAULT;1.1;AES256`), and do not commit `build/` (git-ignored).
Check with `git diff --cached --stat` before committing.

**10. After the PR is merged** - clean up and start the next change from `main`

```bash
git switch main
git pull --ff-only origin main
git branch -d feature/arista-add-vlan30               # delete the local branch
git push origin --delete feature/arista-add-vlan30    # delete it on GitHub (or use the PR button)
```

**Other git commands you will need**

| Task | Command |
|---|---|
| Switch to an existing branch | `git switch <branch>` (or `git checkout <branch>`) |
| List branches | `git branch -a` |
| Pull a teammate's branch | `git fetch origin && git switch <branch>` |
| Pick up new commits from `main` on your branch | `git fetch origin && git rebase origin/main` |
| Undo staged changes (keep the edits) | `git restore --staged <file>` |
| Discard edits to a file | `git restore <file>` (cannot be undone) |
| Add to the last commit before pushing | `git add <file> && git commit --amend --no-edit` |
| See history of the Arista folder | `git log --oneline -- arista/` |

## Before the first push

- Spine management IPs in `inventory/hosts.yml` and the spine-side ports
  (`peer_interface` in each leaf's `uplinks`) are assumptions - the spine running
  configs were not captured. Confirm both.
- Turning on `no bgp default ipv4-unicast` and changing the anycast MAC will
  briefly reset BGP sessions and gateway ARP entries - push in a maintenance window.

## eAPI for the VXLAN dashboard (manual, VTEPs)

The Grafana "Arista VXLAN Statistics" dashboard reads `show vxlan vni` / `show vxlan vtep` over eAPI
using the same read-only `monitor` user as gNMI:

```
management api http-commands
   protocol https
   no shutdown
   !
   vrf mgmt
      no shutdown
```
