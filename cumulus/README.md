# Cumulus Linux - BGP EVPN VXLAN Fabric (2 Spine / 6 Leaf)

Ansible configuration template for a single-tenant BGP EVPN VXLAN fabric on
Cumulus Linux, sized for this project's Phase-1 Cumulus platform. `leaf05`
and `leaf06` are external/border leafs that leak the tenant VRF to an
external WAN/MPLS edge router (e.g. the Cisco IOS backbone from Phase-2/3
of the top-level README).

## Topology

```
        spine1 (AS 65001)        spine2 (AS 65002)
        swp1..swp6                swp1..swp6
           |   \   ...   /  \        |
        +--+----+---- ... ---+------+--+
        |        |    ...    |        |
      leaf01   leaf02   ...  leaf05   leaf06   <- border leafs
     AS 65011 AS 65012      AS 65015 AS 65016
                                 |       |
                            external uplinks (swp3)
                            to WAN / MPLS edge (AS 65100)
```

* Underlay: eBGP unnumbered on every spine-leaf link (unique ASN per
  device), loopbacks advertised as `/32` host routes, ECMP.
* Overlay: EVPN (`address-family l2vpn evpn`) riding the same eBGP
  sessions. Spines set `next-hop-unchanged` and act purely as EVPN route
  reflectors/relays - they hold no VNI/VXLAN state themselves.
* Leafs: `advertise-all-vni`, distributed anycast gateway (symmetric IRB),
  one shared anycast MAC across the fabric.
* Border leafs (`leaf05`, `leaf06`): additional numbered eBGP session in
  the tenant VRF toward the external edge router, redistributing
  `connected`/VRF routes both ways.

## Addressing / numbering scheme

| Device | ASN   | Loopback     | Notes |
|--------|-------|--------------|-------|
| spine1 | 65001 | 10.0.0.1/32  | |
| spine2 | 65002 | 10.0.0.2/32  | |
| leaf01 | 65011 | 10.0.0.11/32 | |
| leaf02 | 65012 | 10.0.0.12/32 | |
| leaf03 | 65013 | 10.0.0.13/32 | |
| leaf04 | 65014 | 10.0.0.14/32 | |
| leaf05 | 65015 | 10.0.0.15/32 | border, swp3 -> 192.168.100.0/30 |
| leaf06 | 65016 | 10.0.0.16/32 | border, swp3 -> 192.168.101.0/30 |

Cabling convention: every leaf's `swp1` goes to `spine1`, `swp2` goes to
`spine2`; on each spine, port `swpN` connects to the Nth leaf in the `leaf`
group (leaf01 -> swp1, ..., leaf06 -> swp6). Adjust
`roles/cumulus_underlay/templates/uplinks.intf.j2` if your GNS3 wiring
differs.

Tenant overlay (`group_vars/all.yml`):

| VLAN | VNI   | Subnet         | Anycast GW    |
|------|-------|----------------|---------------|
| 10   | 10010 | 10.10.10.0/24  | 10.10.10.1    |
| 20   | 10020 | 10.10.20.0/24  | 10.10.20.1    |
| 30   | 10030 | 10.10.30.0/24  | 10.10.30.1    |
| 100  | 10100 | (L3 VNI)       | VRF `TENANT_A`|

## Layout

```
cumulus/
├── ansible.cfg
├── site.yml
├── inventory/hosts.yml          # spine / leaf / border_leaf groups
├── group_vars/                  # fabric-wide + per-role defaults
├── host_vars/                   # per-device ASN, loopback, uplinks
├── samples/                     # rendered example configs (leaf01, spine1) for reference only
└── roles/
    ├── cumulus_underlay/        # /etc/network/interfaces.d fragments + frr.conf (all switches)
    ├── cumulus_overlay/         # VXLAN bridge, VNIs, SVIs, VRF (leafs only)
    └── cumulus_border_leaf/     # external uplink + eBGP peering (leaf05/leaf06 only)
```

`samples/leaf01_sample_config.txt` and `samples/spine1_sample_config.txt` show what
Ansible renders onto a leaf and a spine from the templates above - useful for
reviewing the expected output without running the playbook against a live device.

Config is pushed as `/etc/network/interfaces.d/*.intf` fragments
(`00-loopback`, `10-uplinks`, `20-vxlan`, `30-external`) rather than one
monolithic file, so each role only owns its own fragment.

## Usage

```bash
cd cumulus
ansible-playbook site.yml                 # full fabric
ansible-playbook site.yml --limit spine   # underlay/EVPN control-plane only
ansible-playbook site.yml --limit leaf01  # single device
ansible-playbook site.yml --check --diff  # dry run
```

`inventory/hosts.yml` already has the lab's GNS3 management IPs
(192.168.122.32-39) for spine1/spine2/leaf01-03/leaf05-06 - `leaf04` is
commented out until it's wired up. Update these (or swap in DNS names) if
your GNS3 topology differs, and set `remote_user`/SSH key in `ansible.cfg`
as needed.

## Before using this beyond a lab

* Tighten the border-leaf `address-family ipv4 unicast` in
  `roles/cumulus_underlay/templates/frr.conf.j2` with real prefix-lists /
  route-maps instead of accepting everything from the WAN edge.
* Add MD5/BFD authentication as required by your security policy.
* If leafs need dual-attached host redundancy, layer in MLAG (peerlink +
  `clagd-vxlan-anycast-ip`) - intentionally left out here to keep the
  EVPN template focused.
* Vault-protect any become/SSH secrets before committing them.
