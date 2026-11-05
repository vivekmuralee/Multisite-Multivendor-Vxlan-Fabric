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

## Running

```
cp vault.yml.example group_vars/all/vault.yml   # set the password
ansible-vault encrypt group_vars/all/vault.yml  # vault password in ~/.ansible/arista_vault_pass

ansible-playbook render.yml                     # review build/<host>/*.cfg
ansible-playbook site.yml --check --diff        # preview against the devices
ansible-playbook site.yml
ansible-playbook site.yml --tags cleanup        # one-off removal of stale config
```

From the repo root the same works through the Makefile, e.g.
`make check VENDOR=arista` or `make run VENDOR=arista PLAYBOOK=render.yml`.

## Before the first push

- Spine management IPs in `inventory/hosts.yml` and the spine-side ports
  (`peer_interface` in each leaf's `uplinks`) are assumptions - the spine running
  configs were not captured. Confirm both.
- Turning on `no bgp default ipv4-unicast` and changing the anycast MAC will
  briefly reset BGP sessions and gateway ARP entries - push in a maintenance window.
