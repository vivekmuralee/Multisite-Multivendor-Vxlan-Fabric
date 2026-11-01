# Cumulus Linux - BGP EVPN VXLAN Fabric (2 Spine / 4 Leaf / 2 Border Leaf)

Ansible configuration template for a single-tenant BGP EVPN VXLAN fabric on
Cumulus Linux, sized for this project's Phase-1 Cumulus platform.
`cl-bl-lf-1` and `cl-bl-lf-2` are border leafs: full L2 + L3 EVPN members
of the fabric that also act as border gateways, peering the tenant VRF with
the WAN/MPLS edge routers PE1 and PE2 (the Cisco IOS backbone from
Phase-2/3 of the top-level README).

## Topology

```
        cl-sp-1 (AS 65001)       cl-sp-2 (AS 65002)
        swp1..swp6                swp1..swp6
           |   \   ...   /  \        |
        +--+----+---- ... ---+------+--+
        |        |    ...    |          |
      cl-lf-1  ...  cl-lf-4  cl-bl-lf-1  cl-bl-lf-2   <- border leafs
     AS 65011      AS 65014  AS 65015    AS 65016
                              swp3  swp4  swp3  swp4
                               |     \    /     |
                               |      \  /      |
                               |       \/       |
                               |       /\       |
                              PE1 (AS 65101)  PE2 (AS 65102)
                                WAN / MPLS backbone
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
* Border leafs (`cl-bl-lf-1`, `cl-bl-lf-2`): in the `leaf` group too, so
  they get the same spine uplinks, VNIs, anycast gateways and L3 VNI as
  every leaf. On top of that (`cumulus_border_leaf` role) each one runs a
  numbered eBGP session to both PE1 and PE2 inside the tenant VRF
  (VRF-lite, BFD on, MTU 9216). Policy: accept **only the default route**
  from the PEs (`WAN_IN`), advertise **only the tenant summary**
  `tenant_summary` (10.20.0.0/16, an aggregate of the tenant /24s) to them
  (`WAN_OUT`), and re-export the default route into EVPN as type-5.
* ECMP end to end: each border leaf load-shares the default route across
  PE1 + PE2, every leaf load-shares it across both border leafs (via the
  vrf `multipath aspath-ignore` + `multipaths ebgp` set by the overlay role
  - needed because every path comes from a different ASN), and each PE
  load-shares 10.20.0.0/16 across both border leafs (PE-side config below).

## Addressing / numbering scheme

| Device  | ASN   | Loopback     | Notes |
|---------|-------|--------------|-------|
| cl-sp-1 | 65001 | 10.0.0.1/32  | |
| cl-sp-2 | 65002 | 10.0.0.2/32  | |
| cl-lf-1 | 65011 | 10.0.0.11/32 | |
| cl-lf-2 | 65012 | 10.0.0.12/32 | |
| cl-lf-3 | 65013 | 10.0.0.13/32 | |
| cl-lf-4 | 65014 | 10.0.0.14/32 | |
| cl-bl-lf-1 | 65015 | 10.0.0.15/32 | border, swp3 -> PE1 192.168.100.0/30, swp4 -> PE2 192.168.100.4/30 |
| cl-bl-lf-2 | 65016 | 10.0.0.16/32 | border, swp3 -> PE1 192.168.101.0/30, swp4 -> PE2 192.168.101.4/30 |
| PE1 | 65101 | - | `.2` on each PE1 /30 (`wan_pe_routers` in `group_vars/border_leaf.yml`) |
| PE2 | 65102 | - | `.6` on each PE2 /30 |

Cabling convention: every leaf and border leaf's `swp1` goes to `cl-sp-1`,
`swp2` goes to `cl-sp-2`; on each spine, `swp1..swp4` go to cl-lf-1..4 and
`swp5`/`swp6` go to cl-bl-lf-1/cl-bl-lf-2 (`downlinks` in
`group_vars/spine.yml` - edit that if your GNS3 wiring differs). Border
leafs use `swp3` to PE1 and `swp4` to PE2 (`wan_uplinks` in their
`host_vars`), MTU 9216 like the fabric, for the multi-site Cumulus <->
Arista path - set the PE interfaces to match.

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
├── inventory/hosts.yml          # spine / leaf groups; border_leaf is a child of leaf
├── group_vars/                  # fabric-wide + per-role defaults (spine downlinks, PE ASNs)
├── host_vars/                   # per-device ASN, loopback, WAN uplinks
├── samples/                     # hand-apply NVUE guides per switch, for reference only
└── roles/
    ├── cumulus_underlay/        # loopback, uplinks, underlay/EVPN-transit BGP (all switches)
    ├── cumulus_overlay/         # VXLAN VNIs, anycast gateway (VRR), tenant VRF (leafs + border leafs)
    └── cumulus_border_leaf/     # VRF-lite eBGP to PE1/PE2, route policy, type-5 export (border leafs only)
```

`samples/cl-lf-1_sample_config.txt`, `samples/cl-bl-lf-1_sample_config.txt` and
`samples/cl-sp-1_sample_config.txt` show the `nv set` command sequence Ansible
generates and stages onto a leaf, a border leaf and a spine - useful for
reviewing the expected config without running the playbook against a live
device.

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
ansible-playbook site.yml --limit border_leaf  # border leafs (full leaf config + WAN side)
ansible-playbook site.yml --check --diff  # dry run
```

`inventory/hosts.yml` already has the lab's GNS3 management IPs
(192.168.122.32-39) for cl-sp-1/cl-sp-2, cl-lf-1..4 and cl-bl-lf-1/2.
Update these (or swap in DNS names) if your GNS3 topology differs, and set
`remote_user`/SSH key in `ansible.cfg` as needed.

The PE side is not configured by this repo. Each PE needs, in the tenant
VRF: `mtu 9216` and BFD on its border-leaf-facing /30s, an eBGP neighbor per
border leaf with `default-originate`, and `maximum-paths 2` plus
`bgp bestpath as-path multipath-relax` so it load-shares 10.20.0.0/16
across AS 65015 and AS 65016. A full Cisco IOS example for PE1 is in the
Notes of `samples/cl-bl-lf-1_sample_config.txt`.

## Before using this beyond a lab

* Add maximum-prefix limits on the PE sessions, and keep any new tenant
  subnet inside `tenant_summary` (`group_vars/all/vars.yml`) - anything
  outside it is never advertised to the WAN.
* Add MD5/BFD authentication as required by your security policy.
* If leafs need dual-attached host redundancy, layer in MLAG (peerlink +
  `clagd-vxlan-anycast-ip`) - intentionally left out here to keep the
  EVPN template focused.
* Vault-protect any become/SSH secrets before committing them.
