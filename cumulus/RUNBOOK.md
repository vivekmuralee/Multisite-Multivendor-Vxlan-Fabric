# Cumulus Linux EVPN-VXLAN Fabric - Verification & Validation Runbook

Operational runbook for the 2-spine / 6-leaf fabric built by this repo
(`cl-sp-1/2`, `cl-lf-1..6`; `cl-lf-5/6` are border leafs). Commands are
Cumulus Linux 5.x (NVUE `nv show` plus FRR `vtysh` / Linux tools where NVUE has
no equivalent). Run them on the switch unless stated.

## 0. Reference values (from this repo)

| Item | Value |
|---|---|
| Spine loopbacks / ASN | cl-sp-1 `10.0.0.1` / 65001, cl-sp-2 `10.0.0.2` / 65002 |
| Leaf loopbacks (= VTEP IP) / ASN | cl-lf-N `10.0.0.1N` / `6501N` (lf-1 = 10.0.0.11 / 65011 ... lf-6 = 10.0.0.16 / 65016) |
| Mgmt IPs | sp-1 .32, sp-2 .33, lf-1 .34 ... lf-6 .39 (192.168.122.0/24) |
| Underlay | eBGP unnumbered on swp1 (to sp-1) and swp2 (to sp-2) on leafs, peer-group `UNDERLAY`, BFD on |
| Tenant VRF | `TENANT_A`, L3 VNI `10100` (VLAN 100) |
| L2 VNIs | VLAN 10 / VNI 10010 (10.20.10.0/24), VLAN 20 / 10020 (10.20.20.0/24), VLAN 30 / 10030 (10.20.30.0/24) |
| Anycast GW | `.254` in each subnet, VRR MACs `44:38:39:ff:00:01..03` |
| MTU | 9216 fabric, 9215 on swp links |
| Border leafs | cl-lf-5 / cl-lf-6 `swp3` -> WAN/MPLS edge (AS 65100), peer `192.168.100.2` on lf-5 (check `host_vars` for lf-6) |

Set these once in your shell to paste commands as-is:

```bash
VRF=TENANT_A; L3VNI=10100; VNIS="10010 10020 10030"
```

## 1. Quick fabric health check (run first, ~2 minutes)

On every switch (or via Ansible, section 11):

```bash
nv show system                      # hostname, version, uptime
nv show interface | grep -E "swp|lo|vlan"      # state / link overview
nv show vrf default router bgp neighbor        # all underlay sessions Established?
nv show nve vxlan                    # VXLAN enabled, source address
nv show evpn vni                     # VNIs known
sudo journalctl -u frr --since "-15 min" | tail -30
```

PASS = all links `up`, all BGP neighbors `established`, VNIs listed, no repeating
flap messages in the FRR log.

## 2. Interface status

```bash
nv show interface                       # admin/oper state, speed, MTU, description
nv show interface swp1 link             # detail for one port
nv show interface swp1 link stats       # rx/tx, errors, drops
nv show interface --view=brief          # compact
nv show interface lo ip address
ip -br link                             # Linux view
ip -br addr
sudo ethtool swp1 | grep -E "Speed|Duplex|Link detected"
nv show interface swp1 link mtu         # expect 9215 on fabric links
```

Neighbor cabling check with LLDP (confirms swp1 -> sp-1, swp2 -> sp-2):

```bash
nv show service lldp neighbor
```

| Symptom | Likely cause / next step |
|---|---|
| `oper-status down`, `admin up` | Cable/peer port down or wrong port; check LLDP, peer side |
| Incrementing `in-errors` / `drops` | Bad optic/cable, MTU mismatch; `nv show interface swpX link stats` twice, 10s apart |
| MTU mismatch between ends | Fabric uses 9215 on swp; BGP may establish but large EVPN updates/data stall. Compare both ends |
| Port flaps | `sudo journalctl -u switchd --since "-30 min"` |

## 3. Underlay BGP (loopback reachability)

```bash
nv show vrf default router bgp                       # router-id, ASN
nv show vrf default router bgp neighbor              # state, uptime, pfx counts
nv show vrf default router bgp neighbor swp1         # detail
nv show vrf default router bgp address-family ipv4-unicast route
nv show vrf default router rib ipv4 route            # best routes installed
sudo vtysh -c "show bgp summary"
sudo vtysh -c "show bgp ipv4 unicast 10.0.0.14/32"   # paths to a remote VTEP
nv show vrf default router bgp peer-group UNDERLAY
```

Validate:

1. Leaf has 2 Established neighbors (swp1, swp2). Spine has 6 (one per leaf).
2. Leaf learns the other 5 leaf loopbacks plus both spine loopbacks, each with
   **2 ECMP paths** (via swp1 and swp2):
   ```bash
   nv show vrf default router rib ipv4 route 10.0.0.14/32
   ip route show 10.0.0.14/32          # expect two nexthops (dev swp1, dev swp2)
   ```
3. BFD is up:
   ```bash
   sudo vtysh -c "show bfd peers brief"
   ```
4. Why a session is stuck:
   ```bash
   nv show vrf default router bgp neighbor swp1 | grep -iE "state|reason|last"
   sudo vtysh -c "show bgp neighbors swp1" | grep -iE "state|notif|last reset"
   ```

| State | Meaning |
|---|---|
| Idle / Active | No TCP reached peer: link down, IPv6 LL not resolved, peer not configured |
| Connect | TCP trying; check ACLs, MTU, peer config |
| OpenSent | Mismatch in ASN/`remote-as external`, capabilities |
| Established, 0 pfx | Policy/network statement missing; check `address-family ipv4-unicast network` |

## 4. VXLAN / EVPN tunnel status

### 4.1 VTEP and VNI state (leaf)

```bash
nv show nve vxlan                       # enabled, source address = loopback
nv show nve vxlan mlag                  # n/a unless MLAG used
nv show bridge domain br_default vlan   # VLAN -> VNI mapping
nv show evpn vni                        # all VNIs: type (L2/L3), VRF, remote VTEP count
nv show evpn vni 10010                  # detail: remote VTEPs, MACs, ARP
sudo vtysh -c "show evpn vni"
sudo vtysh -c "show evpn vni detail"
ip -d link show vxlan48                 # Linux VXLAN device (single-vxlan-device mode)
bridge vlan show
```

### 4.2 Remote VTEPs (are tunnels formed?)

```bash
nv show evpn vni 10010 | grep -i remote
sudo vtysh -c "show evpn vni 10010"                  # "Number of remote VTEPs"
bridge fdb show | grep 00:00:00:00:00:00             # head-end replication (type-3) entries
bridge fdb show dev vxlan48 | grep -E "dst 10.0.0"   # dst = remote VTEP IPs
```

**PASS:** each L2 VNI shows the other leafs that carry that VNI as remote VTEPs
(`Remote VTEPs for this VNI: 10.0.0.12 ...`). Each has a type-3 flood-list FDB
entry (`00:00:00:00:00:00 dst <VTEP>`) per remote VTEP.

### 4.3 L3 VNI / tenant VRF

```bash
nv show vrf $VRF evpn                   # L3 VNI, RMAC, VLAN
nv show vrf $VRF
sudo vtysh -c "show vrf vni"            # VRF <-> L3VNI mapping, state Up
sudo vtysh -c "show evpn vni $L3VNI"
sudo vtysh -c "show evpn rmac vni all"  # remote router MACs (one per remote VTEP)
sudo vtysh -c "show evpn next-hops vni all"
```

**PASS:** `show vrf vni` shows `TENANT_A  10100  Up`; `show evpn rmac vni 10100`
has one RMAC per remote VTEP that has the VRF.

### 4.4 Data-plane reachability to a remote VTEP

```bash
ping -c3 -I lo 10.0.0.14                # from lf-1 loopback to remote VTEP (underlay)
ping -c3 -I lo -M do -s 9000 10.0.0.14  # check jumbo path (9028 incl. headers < 9216)
```

If control plane is good but traffic fails, check hardware/switchd:
`sudo journalctl -u switchd | tail`, `nv show system`.

## 5. EVPN BGP session and route-type validation

### 5.1 Is the l2vpn-evpn address-family up?

```bash
sudo vtysh -c "show bgp l2vpn evpn summary"
nv show vrf default router bgp address-family l2vpn-evpn
sudo vtysh -c "show bgp l2vpn evpn vni"
```

Leaf: 2 spine neighbors with prefixes > 0. Spine: 6 leaf neighbors.

### 5.2 Route-type overview

```bash
sudo vtysh -c "show bgp l2vpn evpn route"                 # everything
sudo vtysh -c "show bgp l2vpn evpn route type macip"      # type 2
sudo vtysh -c "show bgp l2vpn evpn route type multicast"  # type 3
sudo vtysh -c "show bgp l2vpn evpn route type prefix"     # type 5
sudo vtysh -c "show bgp l2vpn evpn route type ead"        # type 1 (MLAG/ESI only)
sudo vtysh -c "show bgp l2vpn evpn route type es"         # type 4 (MLAG/ESI only)
sudo vtysh -c "show bgp l2vpn evpn route vni 10010"       # filter per VNI
sudo vtysh -c "show bgp l2vpn evpn route rd <RD>"
sudo vtysh -c "show bgp l2vpn evpn route detail"          # communities, RTs, MAC mobility
```

NVUE equivalent: `nv show vrf default router bgp address-family l2vpn-evpn route`
(also `... route-type macip|multicast|prefix`).

### 5.3 Type-3 (IMET, inclusive multicast) - BUM flood list

Every leaf that has VNI X advertises one type-3 route with its VTEP IP as
next-hop. Expected on lf-1 for VNI 10010: a local type-3 `[3]:[0]:[32]:[10.0.0.11]`
plus one per remote leaf carrying VNI 10010.

```bash
sudo vtysh -c "show bgp l2vpn evpn route type multicast"
sudo vtysh -c "show bgp l2vpn evpn route vni 10010 type multicast"
bridge fdb show | grep 00:00:00:00:00:00        # resulting HER entries
```

**PASS:** count of remote type-3 routes for a VNI == number of remote VTEPs in
`show evpn vni <vni>`. Missing type-3 from a leaf = that leaf has no VNI mapping,
NVE down, or its EVPN session is down. Each is received twice (via sp-1 and sp-2)
in the BGP table; this is normal.

### 5.4 Type-2 (MAC/IP) - host reachability

Format: `[2]:[ESI]:[EthTag]:[MACLen]:[MAC]:[IPLen]:[IP]`

```bash
sudo vtysh -c "show bgp l2vpn evpn route type macip"
sudo vtysh -c "show bgp l2vpn evpn route type macip | include <host-mac>"
sudo vtysh -c "show bgp l2vpn evpn route mac <aa:bb:cc:dd:ee:ff>"
sudo vtysh -c "show bgp l2vpn evpn route mac <mac> ip <ip>"
sudo vtysh -c "show evpn mac vni 10010"          # local + remote MACs in the VNI
sudo vtysh -c "show evpn arp-cache vni 10010"    # IP/MAC bindings (ARP suppression cache)
nv show evpn vni 10010 mac
```

Validate end to end (host H1 on lf-1 VLAN 10, learning on lf-1, reaching lf-3):

1. On **lf-1**: `show evpn mac vni 10010` -> H1 MAC as `local` on a swp port.
2. On **lf-1**: type-2 for H1 MAC and IP is originated (next-hop 10.0.0.11, RT for
   VNI 10010; with symmetric IRB the route also carries the L3VNI 10100 label and RMAC).
3. On **lf-3**: `show bgp l2vpn evpn route mac <H1-MAC>` shows the route with
   next-hop 10.0.0.11, learned from both spines.
4. On **lf-3**: `show evpn mac vni 10010` -> H1 MAC as `remote` via `10.0.0.11`.
5. `bridge fdb show | grep <H1-MAC>` -> `dst 10.0.0.11 ... self extern_learn`.

If the MAC is local but there is no type-2: the host has not sent traffic (generate
an ARP/ping), the VNI is not advertised, or the MAC is frozen by duplicate detection
(`show evpn mac vni 10010 duplicate`).

MAC mobility (VM move): the new leaf advertises with a higher MAC Mobility sequence
number.
```bash
sudo vtysh -c "show bgp l2vpn evpn route mac <mac>" | grep -i "mac mobility"
```

### 5.5 Type-5 (IP prefix) - external and inter-subnet routes

```bash
sudo vtysh -c "show bgp l2vpn evpn route type prefix"
sudo vtysh -c "show bgp vrf $VRF ipv4 unicast"
nv show vrf $VRF router bgp address-family ipv4-unicast route
nv show vrf $VRF router rib ipv4 route
```

On non-border leafs a default or external prefix (for example from the WAN edge)
should appear as type-5 with next-hop = border leaf VTEP (10.0.0.15 / 10.0.0.16),
two paths if both border leafs advertise it.

## 6. Locating a device by MAC address (narrowing down)

Goal: given a MAC (or IP), find which leaf and port it sits on.

### Step 1 - find the MAC from the IP (any leaf)

```bash
ip neigh show vrf $VRF | grep 10.20.10.50
sudo vtysh -c "show evpn arp-cache vni 10010" | grep 10.20.10.50
sudo vtysh -c "show bgp l2vpn evpn route type macip" | grep -B1 -A4 10.20.10.50
```

### Step 2 - locate the MAC

On any leaf:
```bash
sudo vtysh -c "show evpn mac vni all" | grep -i aa:bb:cc:dd:ee:ff
bridge fdb show | grep -i aa:bb:cc:dd:ee:ff
nv show bridge domain br_default mac-table | grep -i aa:bb:cc:dd:ee:ff
```

* `local` + port (e.g. `swp4`) -> **this leaf**, that port. Done.
* `remote` + `10.0.0.1N` -> the host is behind leaf N (`10.0.0.1N` = cl-lf-N).
  Log in to that leaf and repeat; the port will be shown as `local`.

Sort-of one-liner to map VTEP IP to switch: `grep -r "vtep_ip" cumulus/host_vars/`.

### Step 3 - confirm on the owning leaf

```bash
nv show interface swp4 link                      # port up?
nv show interface swp4 bridge domain br_default  # VLAN membership
sudo vtysh -c "show evpn mac vni 10010 mac aa:bb:cc:dd:ee:ff"   # detail, seq number
```

### Special MACs (do not chase these)

| MAC | What |
|---|---|
| `44:38:39:ff:00:01..03` | Anycast gateway VRR MACs, local on every leaf by design |
| RMAC of a VTEP (`nv show vrf TENANT_A evpn`) | Router MAC used on L3VNI routed traffic |
| `00:00:00:00:00:00` | Head-end-replication flood entry, not a host |

MAC seen on two leafs / flapping: look for a loop or duplicate address:
`sudo vtysh -c "show evpn mac vni 10010 duplicate"` and `journalctl -u frr | grep -i dup`.

## 7. Layer 3: VRF routing and anycast gateway

```bash
nv show interface vlan10 ip vrr                  # VRR state/MAC
ip -br addr show vlan10 vlan10-v0                # SVI and VRR macvlan
nv show vrf $VRF router rib ipv4 route           # routes in the tenant VRF
ip route show vrf $VRF
sudo vtysh -c "show ip route vrf $VRF"
ip neigh show vrf $VRF
```

Checks:

* Local subnets 10.20.10/20/30.0/24 as connected; remote subnets as `via <RMAC-VTEP> dev vlan100 onlink` (L3VNI SVI) with `proto bgp`.
* Same VRR IP/MAC on every leaf (`44:38:39:ff:00:0X`).
* Symmetric IRB: from lf-1, a host route to a remote-subnet host (learned via type-2 with IP) points to remote VTEP over vlan100.

## 8. Connectivity testing and traceroute

### 8.1 Rules that make results meaningful

* Underlay (loopback to loopback) is in the **default** VRF; tenant traffic is in `$VRF`. Always choose the VRF explicitly with `ip vrf exec` (or `-I`).
* Source from the right interface: `-I lo` for underlay tests, `-I vlan10` for tenant tests.
* In VXLAN the tenant path appears as one routed hop to the remote anycast gateway; the underlay hops (spine) are encapsulated and not visible in a tenant traceroute. Test the two layers separately.

### 8.2 Leaf-to-leaf (underlay)

```bash
ping -c3 -I lo 10.0.0.12
traceroute -s 10.0.0.11 10.0.0.12         # expect: spine -> 10.0.0.12
traceroute -s 10.0.0.11 -n -w1 10.0.0.16  # one of sp-1 / sp-2 shown, ECMP-dependent
mtr -rwn -c 10 -a 10.0.0.11 10.0.0.12     # if mtr installed
```

Cover ECMP: run `traceroute` with different sources/ports (`-p`) or check each uplink explicitly:
```bash
ping -c3 -I swp1 <spine-LL-or-loopback>
```

### 8.3 Leaf-to-leaf (overlay / tenant VRF)

From lf-1, via the anycast gateway on VLAN 10 to a host/SVI on another leaf:

```bash
sudo ip vrf exec $VRF ping -c3 -I vlan10 10.20.20.254          # local GW, sanity
sudo ip vrf exec $VRF ping -c3 -I vlan10 10.20.20.50         # host in other subnet behind lf-3
sudo ip vrf exec $VRF traceroute -n -s 10.20.10.254 10.20.20.50
ping -c3 -I vlan10 10.20.10.60 -M do -s 1422                 # same-subnet (L2 VNI) host, DF set, 1500-MTU hosts
```

Same-subnet test (L2 VNI) uses a host in VLAN 10 on a remote leaf; if it fails
while the underlay works, go to sections 4.2 and 5.3/5.4. Inter-subnet (L3 VNI)
failures: sections 4.3 and 7.

Use a host-side ping from a real endpoint when you can; pings from the switch
SVI test the control plane but not the exact host path.

### 8.4 To the external network (border leafs and beyond)

```bash
# On border leaf (cl-lf-5): the eBGP session in the tenant VRF
nv show vrf $VRF router bgp neighbor 192.168.100.2
sudo vtysh -c "show bgp vrf $VRF summary"
sudo vtysh -c "show bgp vrf $VRF ipv4 unicast neighbors 192.168.100.2 advertised-routes"
sudo vtysh -c "show bgp vrf $VRF ipv4 unicast neighbors 192.168.100.2 routes"
sudo ip vrf exec $VRF ping -c3 192.168.100.2
sudo ip vrf exec $VRF ping -c3 -I vlan10 <external-prefix-host>
sudo ip vrf exec $VRF traceroute -n -s 10.20.10.254 <external-ip>

# On a normal leaf (cl-lf-1): external reachable through border VTEP
nv show vrf $VRF router rib ipv4 route <external-prefix>
sudo ip vrf exec $VRF traceroute -n -s 10.20.10.254 <external-ip>
```

Expected from lf-1 toward external: next-hop = border leaf RMAC/VTEP (10.0.0.15
and/or 10.0.0.16), first visible hop is the border leaf VRF address, then the WAN edge
(192.168.100.2 or the lf-6 equivalent), then the WAN.

Reverse direction: from the external router confirm it received the fabric subnets
(10.20.10.0/24 ... 10.20.30.0/24) from AS 65015/65016 and can reach the tenant gateway.

### 8.5 Packet capture (last resort)

```bash
sudo tcpdump -i swp1 -nn -e udp port 4789          # VXLAN-encapsulated tenant traffic on the uplink
sudo tcpdump -i swp1 -nn -vv 'udp port 4789 and host 10.0.0.14'
sudo tcpdump -i vlan10 -nn icmp                    # decapsulated, on the SVI
sudo tcpdump -i swp1 -nn tcp port 179              # BGP
```

VNI is in the VXLAN header; confirm outer src = local VTEP, outer dst = remote VTEP,
VNI = 10010 (L2) or 10100 (L3).

## 9. Spine-specific checks

Spines hold no VNI/VXLAN state; they only relay EVPN routes.

```bash
nv show vrf default router bgp neighbor                # 6 leafs Established
sudo vtysh -c "show bgp l2vpn evpn summary"
sudo vtysh -c "show bgp l2vpn evpn route type multicast" | grep -c "\[3\]"   # one per leaf per VNI
sudo vtysh -c "show bgp ipv4 unicast"                  # all 8 loopbacks
nv show interface --view=brief
```

PASS: type-2/3/5 routes from every leaf are present and are re-advertised with the
original VTEP as next-hop (next-hop is the leaf loopback, not the spine).
If a spine shows no EVPN routes from a leaf but IPv4 is fine, the `l2vpn-evpn` address
family is not activated on the peer-group on one side.

## 10. Troubleshooting decision tree

```
Host A cannot reach Host B
|
+-- Same subnet (L2 VNI)?
|     +-- MAC of B visible on A's leaf as remote?          no -> 5.4 (type-2), 6
|     +-- Type-3 / remote VTEP list complete for the VNI?   no -> 5.3, 4.2
|     +-- Underlay ping loopback-to-loopback ok?            no -> 3, 2
|
+-- Different subnet (L3 VNI)?
|     +-- Gateway 10.20.x.254 reachable from A?               no -> 7 (VRR, SVI)
|     +-- Route to B's subnet / host in VRF on A's leaf?    no -> 5.4/5.5, 4.3
|     +-- show vrf vni = Up, RMACs for remote VTEP present? no -> 4.3
|
+-- External?
      +-- Border leaf eBGP to WAN Established?              no -> 8.4
      +-- Default/prefix received and exported as type-5?   no -> 5.5
      +-- Return route on WAN edge for 10.20.x.0/24?        no -> 8.4 (advertised-routes)
```

Common faults:

| Symptom | Check |
|---|---|
| Underlay up, no EVPN routes | `l2vpn-evpn` enabled on peer-group both ends; `show bgp l2vpn evpn summary` |
| VNI not listed in `show evpn vni` | `nv show bridge domain br_default vlan` mapping, `nve vxlan enable on` |
| Remote VTEP count lower than expected | Missing type-3 from that leaf; check that leaf's VNI config and its BGP |
| Type-2 present, ping fails | MTU (VXLAN adds 50 bytes), ARP suppression cache, RMAC missing, hardware/switchd errors |
| L3 traffic black-holed | VRF `evpn vni` missing, `show vrf vni` down, no RMAC |
| Intermittent loss to one host | Duplicate MAC/IP (`duplicate`), MAC mobility flapping |
| Config applied but no effect | `nv config diff`, `nv config history`, `nv config show -o commands` |
| `ifreload-nvue.service` fails: "mixing traditional vxlan with single vxlan device", "Address already in use" | Pre-NVUE `/etc/network/interfaces.d/*.intf` fragments still present. Move them out, `ip link del` old `vniNNNNN` devices, `sudo ifreload -a` (see "Before you start" in `samples/`) |
| `show vrf vni` State Down, VxLAN IF `vniNNNNN` instead of `vxlan48` | Same cause as above: old traditional VXLAN devices in use |

## 11. Running checks across the fabric with Ansible

From `cumulus/`:

```bash
# Quick sweeps
ansible fabric -m shell -a "nv show vrf default router bgp neighbor" 
ansible leaf   -m shell -a "sudo vtysh -c 'show bgp l2vpn evpn summary'"
ansible leaf   -m shell -a "sudo vtysh -c 'show vrf vni'"
ansible leaf   -m shell -a "nv show evpn vni"

# Find a MAC across all leafs
ansible leaf -m shell -a "sudo vtysh -c 'show evpn mac vni all' | grep -i aa:bb:cc:dd:ee:ff"

# Ping every remote VTEP from each leaf
ansible leaf -m shell -a 'for ip in 10.0.0.11 10.0.0.12 10.0.0.13 10.0.0.14 10.0.0.15 10.0.0.16; do ping -c1 -W1 -I lo $ip >/dev/null && echo "$ip ok" || echo "$ip FAIL"; done'
```

(Add `-b` if sudo is needed and not already set in `ansible.cfg`; use the vault option
your inventory expects.)

## 12. Post-change validation checklist

Print/paste into the change ticket. Mark each as PASS/FAIL.

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Interfaces up | `nv show interface --view=brief` | swp links up, MTU 9215 |
| 2 | LLDP topology | `nv show service lldp neighbor` | matches cabling |
| 3 | Underlay BGP | `nv show vrf default router bgp neighbor` | all Established (leaf 2, spine 6) |
| 4 | BFD | `vtysh -c "show bfd peers brief"` | all up |
| 5 | Loopback ECMP | `ip route show 10.0.0.1X/32` | 2 next-hops |
| 6 | VTEP ping | `ping -I lo 10.0.0.1X` | 0% loss, jumbo ok |
| 7 | EVPN AF | `vtysh -c "show bgp l2vpn evpn summary"` | all Established, pfx > 0 |
| 8 | VNIs | `nv show evpn vni` | 10010/20/30 and 10100 present |
| 9 | Remote VTEPs | `vtysh -c "show evpn vni 10010"` | all carrying leafs listed |
| 10 | Type-3 | `show bgp l2vpn evpn route type multicast` | 1 per remote VTEP per VNI |
| 11 | Type-2 | `show bgp l2vpn evpn route type macip` | test host MAC/IP learned remotely |
| 12 | L3 VNI | `vtysh -c "show vrf vni"` | TENANT_A 10100 Up; RMACs present |
| 13 | Anycast GW | `nv show interface vlan10 ip vrr` | same IP/MAC on all leafs |
| 14 | Inter-subnet ping | `ip vrf exec TENANT_A ping ...` | success across leafs |
| 15 | External BGP (lf-5/6) | `show bgp vrf TENANT_A summary` | WAN peer Established |
| 16 | External reachability | `ip vrf exec TENANT_A traceroute ...` | via border leaf to WAN |
| 17 | Logs clean | `journalctl -u frr --since "-15 min"` | no flaps / errors |
| 18 | Config saved | `nv config history \| head` | latest applied revision is expected one |
| 19 | No unsaved/pending changes | `nv config diff applied startup`; `nv config diff` | both empty |
| 20 | Matches intended config | `nv config show -o commands` vs `samples/<host>_sample_config.txt` (13.4) | only unmanaged system lines differ |

## 13. Running configuration in set syntax (`nv config show`)

`nv config show -o commands` prints the configuration as the `nv set` commands
that build it, in the same format as the files in [samples/](samples/) and the
Ansible templates.

### 13.1 Full configuration

```bash
nv config show -o commands              # applied (running) config as nv set commands
nv config show                          # same config in YAML (default)
nv config show -o json
nv config show -r applied -o commands   # explicitly the applied revision
nv config show -r startup -o commands   # what loads on reboot (/etc/nvue.d/startup.yaml)
nv config show -r pending -o commands   # staged with nv set but not yet applied
```

### 13.2 Filtering by section

`nv config show` prints the whole config, so filter it with `grep`:

```bash
nv config show -o commands | grep "interface lo"                       # loopback
nv config show -o commands | grep -E "interface swp[0-9]+ "            # fabric ports
nv config show -o commands | grep "router bgp"                         # all BGP
nv config show -o commands | grep "vrf default router bgp"             # underlay BGP
nv config show -o commands | grep "peer-group UNDERLAY"                # peer-group
nv config show -o commands | grep -E "nve|bridge domain"               # VXLAN / VLAN-VNI map
nv config show -o commands | grep -E "interface vlan(10|20|30|100) "   # SVIs + VRR
nv config show -o commands | grep "vrf TENANT_A"                       # tenant VRF, L3VNI, ext BGP
nv config show -o commands | grep -E "evpn"                            # EVPN settings
nv config show -o commands | grep "192.168.100"                        # border-leaf WAN peering (lf-5/6)
```

Applied value of a single object without the full dump:

```bash
nv show interface vlan10 --applied
nv show vrf TENANT_A evpn --applied
nv show vrf default router bgp --applied -o json
```

(`--applied` = config, `--operational` = live state; omitting both shows both side by side.)

### 13.3 Changes, history and drift

```bash
nv config diff                          # pending vs applied (what nv config apply would change)
nv config diff -o commands              # same, as nv set/unset commands
nv config history                       # applied revisions, user, time
nv config history | head -5
nv config diff <rev-A> <rev-B>          # compare two revisions from history
nv config diff applied startup          # applied but not saved?  (empty = in sync)
nv config save                          # write applied config to startup
```

Revert after a bad change: `nv config apply <rev-id> -y` re-applies an earlier
revision from `nv config history` (some releases use `nv config apply rev <id>`).

### 13.4 Compare a switch with its sample / Ansible-rendered config

```bash
# On the switch
nv config show -o commands > /tmp/$(hostname)_running.txt

# On the Ansible host, from cumulus/
scp cumulus@192.168.122.34:/tmp/cl-lf-1_running.txt .
diff <(grep '^nv set' samples/cl-lf-1_sample_config.txt | sort) \
     <(grep '^nv set' cl-lf-1_running.txt | sort)
```

Collect from the whole fabric:

```bash
ansible fabric -m shell -a "nv config show -o commands" > fabric_running_config.txt
```

Expected differences that are not drift: system/management lines (hostname,
mgmt VRF, eth0, users, NTP/DNS, `nv set system ...`) that the roles don't manage,
and ordering. Anything under `interface lo/swp/vlan`, `nve`, `bridge domain`,
`router bgp` or `vrf TENANT_A` that differs from the sample is drift and should be
fixed by re-running the playbook.

## Appendix: handy command map (Cumulus -> concept)

| Need | NVUE | FRR / Linux |
|---|---|---|
| BGP neighbors | `nv show vrf default router bgp neighbor` | `vtysh -c "show bgp summary"` |
| EVPN peers | `nv show vrf default router bgp address-family l2vpn-evpn` | `vtysh -c "show bgp l2vpn evpn summary"` |
| VNI list | `nv show evpn vni` | `vtysh -c "show evpn vni"` |
| MAC table | `nv show bridge domain br_default mac-table` | `bridge fdb show`, `vtysh -c "show evpn mac vni all"` |
| ARP/ND | `nv show vrf TENANT_A neighbor` (platform-dependent) | `ip neigh show vrf TENANT_A` |
| Routes in VRF | `nv show vrf TENANT_A router rib ipv4 route` | `ip route show vrf TENANT_A` |
| Interfaces | `nv show interface` | `ip -br link`, `ethtool` |
| Applied config | `nv config show` | `/etc/frr/frr.conf`, `vtysh -c "show run"` |
| Applied config, set syntax | `nv config show -o commands` | n/a |
| Pending / saved diff | `nv config diff`, `nv config diff applied startup` | n/a |

> Note: some `nv show` sub-commands and output formats vary slightly between
> Cumulus Linux 5.x releases. If one is not recognised, use the FRR/Linux equivalent
> in the right-hand column; they are stable across releases. Commands in this file have
> not been executed against the lab fabric.
