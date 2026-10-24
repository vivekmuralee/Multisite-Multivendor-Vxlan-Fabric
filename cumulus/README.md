# Cumulus Linux - BGP EVPN VXLAN Fabric (2 Spine / 6 Leaf)

Ansible configuration template for a single-tenant BGP EVPN VXLAN fabric on
Cumulus Linux, sized for this project's Phase-1 Cumulus platform. `cl-lf-5`
and `cl-lf-6` are external/border leafs that leak the tenant VRF to an
external WAN/MPLS edge router (e.g. the Cisco IOS backbone from Phase-2/3
of the top-level README).

## Topology

```
        cl-sp-1 (AS 65001)       cl-sp-2 (AS 65002)
        swp1..swp6                swp1..swp6
           |   \   ...   /  \        |
        +--+----+---- ... ---+------+--+
        |        |    ...    |        |
      cl-lf-1  cl-lf-2  ...  cl-lf-5  cl-lf-6   <- border leafs
     AS 65011 AS 65012      AS 65015 AS 65016
                                 |       |
                            external uplinks (swp3)
                            to WAN / MPLS edge (AS 65100)
```

* Underlay: eBGP unnumbered on every spine-leaf link (unique ASN per
  device), loopbacks advertised as `/32` host routes, ECMP.
* Overlay: EVPN (`address-family l2vpn-evpn`) riding the same eBGP
  sessions. Spines act purely as EVPN route reflectors/relays - they hold
  no VNI/VXLAN state themselves, and NVUE's default next-hop behaviour for
  this address family already passes EVPN routes through unchanged (the
  old raw-FRR config had to say this explicitly; NVUE doesn't).
* Leafs: every locally-configured VNI is advertised automatically once
  `nve vxlan` and the vrf's `l2vpn-evpn` address family are enabled (no
  separate "advertise-all-vni" toggle in NVUE), distributed anycast
  gateway via VRR (symmetric IRB), one shared anycast MAC across the
  fabric.
* Border leafs (`cl-lf-5`, `cl-lf-6`): additional numbered eBGP session in
  the tenant VRF toward the external edge router, redistributing
  `connected`/VRF routes both ways.

## Addressing / numbering scheme

| Device  | ASN   | Loopback     | Notes |
|---------|-------|--------------|-------|
| cl-sp-1 | 65001 | 10.0.0.1/32  | |
| cl-sp-2 | 65002 | 10.0.0.2/32  | |
| cl-lf-1 | 65011 | 10.0.0.11/32 | |
| cl-lf-2 | 65012 | 10.0.0.12/32 | |
| cl-lf-3 | 65013 | 10.0.0.13/32 | |
| cl-lf-4 | 65014 | 10.0.0.14/32 | |
| cl-lf-5 | 65015 | 10.0.0.15/32 | border, swp3 -> 192.168.100.0/30 |
| cl-lf-6 | 65016 | 10.0.0.16/32 | border, swp3 -> 192.168.101.0/30 |

Cabling convention: every leaf's `swp1` goes to `cl-sp-1`, `swp2` goes to
`cl-sp-2`; on each spine, port `swpN` connects to the Nth leaf in the `leaf`
group (cl-lf-1 -> swp1, ..., cl-lf-6 -> swp6). Adjust
`roles/cumulus_underlay/templates/nv_underlay.sh.j2` if your GNS3 wiring
differs.

Tenant overlay (`group_vars/all/vars.yml`):

| VLAN | VNI   | Subnet         | Anycast GW    |
|------|-------|----------------|---------------|
| 10   | 10010 | 10.20.10.0/24  | 10.20.10.254  |
| 20   | 10020 | 10.20.20.0/24  | 10.20.20.254  |
| 30   | 10030 | 10.20.30.0/24  | 10.20.30.254  |
| 100  | 10100 | (L3 VNI)       | VRF `TENANT_A`|

## Layout

```
cumulus/
├── ansible.cfg
├── site.yml
├── inventory/hosts.yml          # spine / leaf / border_leaf groups
├── group_vars/                  # fabric-wide + per-role defaults
├── host_vars/                   # per-device ASN, loopback, uplinks
├── samples/                     # rendered example NVUE command sets (cl-lf-1, cl-sp-1) for reference only
└── roles/
    ├── cumulus_underlay/        # loopback, uplinks, underlay/EVPN-transit BGP (all switches)
    ├── cumulus_overlay/         # VXLAN VNIs, anycast gateway (VRR), tenant VRF (leafs only)
    └── cumulus_border_leaf/     # external uplink + eBGP peering (cl-lf-5/cl-lf-6 only)
```

`samples/cl-lf-1_sample_config.txt` and `samples/cl-sp-1_sample_config.txt` show the
`nv set` command sequence Ansible generates and stages onto a leaf and a spine -
useful for reviewing the expected config without running the playbook against
a live device.

**Config is delivered via NVUE**, not by editing `/etc/network/interfaces`
or `/etc/frr/frr.conf` directly. Cumulus Linux 5.x runs NVUE as the actual
source of truth for both of those files; editing them by hand (the
ifupdown2/frr.conf approach this repo used to take) gets silently reverted
the next time NVUE reconciles, since NVUE doesn't know about changes made
outside itself. Each role instead renders a small script of `nv set ...`
commands (see `templates/nv_*.sh.j2`), runs it to stage those changes into
NVUE's pending revision, then commits everything in one `nv config apply`.
One practical upshot: there's no separate "enable the FRR daemon" or
"restart frr" step anywhere in these roles anymore (compare with older
revisions of this file) - `nv config apply` regenerates `frr.conf`/
`/etc/frr/daemons` and restarts whatever it needs to, atomically, as part
of committing the revision.

## Usage

```bash
cd cumulus
ansible-playbook site.yml                 # full fabric
ansible-playbook site.yml --limit spine   # underlay/EVPN control-plane only
ansible-playbook site.yml --limit cl-lf-1 # single device
ansible-playbook site.yml --check --diff  # dry run
```

`inventory/hosts.yml` already has the lab's GNS3 management IPs
(192.168.122.32-39) for cl-sp-1/cl-sp-2/cl-lf-1-3/cl-lf-5-6 - `cl-lf-4` is
commented out until it's wired up. Update these (or swap in DNS names) if
your GNS3 topology differs, and set `remote_user`/SSH key in `ansible.cfg`
as needed.

## Before using this beyond a lab

* Tighten the border-leaf eBGP session in
  `roles/cumulus_border_leaf/templates/nv_border_leaf.sh.j2` with real
  prefix-lists / route-maps (`nv set vrf ... router bgp neighbor ...
  address-family ipv4-unicast policy ...`) instead of accepting everything
  from the WAN edge.
* Add MD5/BFD authentication as required by your security policy.
* If leafs need dual-attached host redundancy, layer in MLAG (peerlink +
  `clagd-vxlan-anycast-ip`) - intentionally left out here to keep the
  EVPN template focused.
* Vault-protect any become/SSH secrets before committing them.
