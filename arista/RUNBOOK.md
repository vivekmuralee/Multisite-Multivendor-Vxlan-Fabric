# Arista EOS EVPN-VXLAN Fabric - Verification & Validation Runbook

Operational runbook for the Arista EOS EVPN-VXLAN fabric (spine/leaf, border leafs
to the MPLS backbone). It mirrors [../cumulus/RUNBOOK.md](../cumulus/RUNBOOK.md) section
for section, so a check has the same number on both vendors. Commands are Arista EOS
4.2x (vEOS / cEOS / hardware). Run them on the switch in privileged exec mode unless
stated.

> The Arista fabric is not built in this repo yet. Section 0 reuses the Cumulus
> addressing and tenant design as placeholders. **Edit the table and the shell
> variables to match the real build** before using the expected values below.

## 0. Reference values (placeholders - adjust to the build)

| Item | Value |
|---|---|
| Spines / ASN | `ar-sp-1` `10.1.0.1` / 65101, `ar-sp-2` `10.1.0.2` / 65101 (shared spine ASN) |
| Leafs / ASN | `ar-lf-N` loopback0 `10.1.0.1N` (= VTEP IP), ASN `6511N` (one ASN per leaf, or per MLAG pair) |
| Underlay | eBGP on routed point-to-point links `Ethernet1` (to sp-1) and `Ethernet2` (to sp-2), BFD on |
| Overlay | eBGP multihop l2vpn-evpn between leaf Loopback0 and spine Loopback0, `send-community extended` |
| VXLAN interface | `Vxlan1`, source `Loopback0`, UDP 4789 |
| Tenant VRF | `TENANT_A`, L3 VNI `10100` (VLAN 100) |
| L2 VNIs | VLAN 10 / VNI 10010 (10.20.10.0/24), VLAN 20 / 10020 (10.20.20.0/24), VLAN 30 / 10030 (10.20.30.0/24) |
| Anycast GW | `.254` in each subnet via `ip address virtual`, `ip virtual-router mac-address 0044.3839.ff00` |
| MTU | 9214 on fabric links (EOS maximum), 9214 on the SVIs you route over |
| Border leafs | `ar-lf-5` / `ar-lf-6` -> WAN/MPLS edge, eBGP in `TENANT_A` |

Placeholders to substitute in the commands below:

```
VRF       = TENANT_A
L3VNI     = 10100
VNIs      = 10010 10020 10030
VTEP IPs  = 10.1.0.11 ... 10.1.0.16
```

EOS has no shell variables in the CLI, so replace them by hand. In the EOS `bash`
sub-shell you can export them if you need them for Linux tools.

Useful EOS habits:

* `| include <text>`, `| exclude <text>`, `| section <text>`, `| begin <text>`, `| json` filter output.
* `show <cmd> | no-more` turns paging off for one command (`terminal length 0` for the session).
* `show ... detail` on most BGP and VXLAN commands adds the attribute view.

## 1. Quick fabric health check (run first, ~2 minutes)

On every switch (or via Ansible, section 11):

```
show version                              ! model, EOS version, uptime
show interfaces status                    ! link overview
show ip bgp summary                       ! underlay sessions Established?
show bgp evpn summary                     ! overlay sessions Established?
show interfaces vxlan 1                   ! VXLAN up, source, VNI map
show vxlan vni                            ! VNIs known
show vxlan config-sanity                  ! one-shot consistency check
show logging last 15 minutes
```

PASS = all links `connected`, all BGP neighbors `Estab`, VNIs listed,
`show vxlan config-sanity` reports no failures, no repeating flap messages in the log.

## 2. Interface status

```
show interfaces status                    ! state, VLAN/routed, duplex, speed, type
show interfaces Ethernet1                 ! detail for one port (MTU, counters, last flap)
show interfaces Ethernet1 counters errors ! CRC, runts, giants, FCS
show interfaces counters rates            ! bits/sec per port
show interfaces counters discards
show ip interface brief
show ip interface Loopback0
show interfaces Ethernet1 | include MTU
show interfaces transceiver Ethernet1     ! optic power/DOM (hardware)
```

Neighbor cabling check with LLDP (confirms Ethernet1 -> sp-1, Ethernet2 -> sp-2):

```
show lldp neighbors
show lldp neighbors Ethernet1 detail
```

| Symptom | Likely cause / next step |
|---|---|
| `notconnect` / `errdisabled` | Cable or peer port down; `show interfaces status errdisabled`, check LLDP and the peer side |
| Incrementing `inErrors` / discards | Bad optic or cable, MTU mismatch; run `show interfaces Ethernet1 counters errors` twice, 10 s apart |
| MTU mismatch between ends | BGP may establish but large EVPN updates and data stall. Compare both ends (`show interfaces Ethernet1 | include MTU`) |
| Port flaps | `show logging | include LINEPROTO|UPDOWN`, `show interfaces Ethernet1 | include flap` |

## 3. Underlay BGP (loopback reachability)

```
show ip bgp summary                              ! state, uptime, prefix counts
show ip bgp neighbors 10.1.1.0                   ! detail for one peer (use the peer link IP)
show ip bgp                                      ! BGP table
show ip bgp 10.1.0.14/32                         ! paths to a remote VTEP
show ip route bgp                                ! best routes installed
show ip route 10.1.0.14/32                       ! expect two next-hops (ECMP)
show running-config | section router bgp
show bfd peers                                   ! BFD state per session
```

Validate:

1. Leaf has 2 Established underlay neighbors (Ethernet1, Ethernet2). Spine has 6 (one per leaf).
2. Leaf learns the other 5 leaf loopbacks plus both spine loopbacks, each with
   **2 ECMP paths**:
   ```
   show ip route 10.1.0.14/32
   show ip bgp 10.1.0.14/32
   ```
   ECMP needs `maximum-paths 2 ecmp 2` under `router bgp` (the default is 1 path). If
   the leafs use different ASNs, also set `bgp bestpath as-path multipath-relax`.
3. BFD is up: `show bfd peers` -> `Up` for every underlay neighbor.
4. Why a session is stuck:
   ```
   show ip bgp neighbors 10.1.1.0 | include BGP state|Last reset|Notification
   show ip bgp neighbors 10.1.1.0 | section Local|Remote
   show logging | include BGP
   ```

| State | Meaning |
|---|---|
| Idle | Peer not configured or `shutdown`; check the neighbor line, ASN, peer-group, and `show ip interface brief` |
| Active | No TCP reached the peer: link down, wrong peer IP, ACL, no route to the multihop address |
| Connect | TCP trying; check ACLs, MTU, peer config |
| OpenSent | Mismatch in ASN or capabilities (`remote-as`, address family) |
| Estab, 0 pfx | Policy or `network`/`redistribute connected` missing for Loopback0 |

## 4. VXLAN / EVPN tunnel status

### 4.1 VTEP and VNI state (leaf)

```
show interfaces vxlan 1                  ! up/up, source interface, flood mode, VLAN-VNI map
show vxlan vni                           ! all VNIs: type (L2/L3), VRF/VLAN, source
show vxlan vtep                          ! remote VTEPs and how they were learned
show vxlan address-table                 ! MACs learned over VXLAN
show vxlan config-sanity detail          ! detail for every failed check
show vxlan counters vtep                 ! encap/decap counters per remote VTEP (hardware)
show running-config | section Vxlan1
show vlan                                ! local VLANs
```

### 4.2 Remote VTEPs (are tunnels formed?)

```
show vxlan vtep                          ! every remote VTEP
show vxlan flood vtep                    ! head-end replication list (from type-3 routes)
show vxlan flood vtep vlan 10
show vxlan address-table vtep 10.1.0.14  ! MACs behind one VTEP
show interfaces vxlan 1 | include Replication|flood
```

**PASS:** `show vxlan vtep` lists each other leaf that carries the VNI, and
`show vxlan flood vtep` has one entry per remote VTEP per VLAN (the HER list built
from type-3 routes).

### 4.3 L3 VNI / tenant VRF

```
show vrf                                 ! VRF list, interfaces, route count
show vrf TENANT_A
show vxlan vni                           ! TENANT_A <-> 10100 mapping
show running-config | section vrf instance TENANT_A
show ip route vrf TENANT_A
show bgp evpn route-type ip-prefix ipv4  ! type-5 routes
show vxlan address-table vrf TENANT_A    ! remote router MACs (if supported on the platform)
show bgp evpn route-type mac-ip          ! RMAC extended community on the type-2/5 routes
```

**PASS:** `show vxlan vni` lists VNI 10100 as `L3` for `TENANT_A`; remote routes in the
VRF point to a remote VTEP next-hop. `ip routing vrf TENANT_A` must be enabled
(`show ip route vrf TENANT_A` fails or is empty if not).

### 4.4 Data-plane reachability to a remote VTEP

```
ping 10.1.0.14 source Loopback0 repeat 3
ping 10.1.0.14 source Loopback0 size 9000 df-bit repeat 3   ! jumbo path check
```

If the control plane is good but traffic fails, check hardware programming
(`show vxlan counters vtep`, `show platform ... ` on hardware) and the agent logs:
`show logging | include Vxlan|Bgp|Rib`, `show agent logs` (platform dependent).

## 5. EVPN BGP session and route-type validation

### 5.1 Is the l2vpn-evpn address-family up?

```
show bgp evpn summary
show bgp evpn instance                   ! per-VNI/VLAN-aware instances, RD/RT
show running-config | section address-family evpn
show bgp evpn route-type imet            ! (see 5.3) - confirms the table is populated
```

Leaf: 2 spine neighbors with prefixes > 0. Spine: 6 leaf neighbors. EVPN sessions
are normally loopback-to-loopback eBGP multihop; `show ip bgp summary` and
`show bgp evpn summary` are two separate checks.

### 5.2 Route-type overview

```
show bgp evpn                                    ! everything
show bgp evpn route-type auto-discovery          ! type 1 (ESI only)
show bgp evpn route-type mac-ip                  ! type 2
show bgp evpn route-type imet                    ! type 3
show bgp evpn route-type ethernet-segment        ! type 4 (ESI only)
show bgp evpn route-type ip-prefix ipv4          ! type 5
show bgp evpn route-type mac-ip detail           ! communities, RTs, MAC mobility
show bgp evpn rd 10.1.0.11:10010                 ! filter per RD
show bgp evpn route-type imet vni 10010          ! filter per VNI
```

(The `vni` keyword is available on recent EOS releases. If the CLI rejects it, filter
with `| include 10010`.)

### 5.3 Type-3 (IMET, inclusive multicast) - BUM flood list

Every leaf that has VNI X advertises one type-3 route with its VTEP IP as next-hop.
Expected on lf-1 for VNI 10010: a local type-3 `RD 10.1.0.11:10010` plus one per remote
leaf carrying VNI 10010.

```
show bgp evpn route-type imet
show bgp evpn route-type imet vni 10010
show vxlan flood vtep vlan 10                    ! resulting HER entries
```

**PASS:** the count of remote type-3 routes for a VNI equals the number of remote VTEPs
in `show vxlan vtep`. A missing type-3 from a leaf = that leaf has no VNI mapping,
the VXLAN interface is down, or its EVPN session is down. Each type-3 is received
twice (via sp-1 and sp-2); this is normal.

### 5.4 Type-2 (MAC/IP) - host reachability

Format: `RD:[2]:ethtag:MACLen:MAC:IPLen:IP`

```
show bgp evpn route-type mac-ip
show bgp evpn route-type mac-ip <aaaa.bbbb.cccc>        ! one MAC
show bgp evpn route-type mac-ip <aaaa.bbbb.cccc> detail
show bgp evpn route-type mac-ip | include <host-ip>
show mac address-table vlan 10                           ! local + VXLAN-learned
show vxlan address-table vlan 10                         ! VXLAN-learned only
show ip arp vrf TENANT_A                                 ! IP/MAC bindings
```

Validate end to end (host H1 on lf-1 VLAN 10, learning on lf-1, reaching lf-3):

1. On **lf-1**: `show mac address-table address <H1-MAC>` -> `DYNAMIC` on a local port.
2. On **lf-1**: type-2 for H1 MAC and IP is originated (next-hop 10.1.0.11, RT for
   VNI 10010; with symmetric IRB the route also carries L3VNI 10100 and the RMAC).
3. On **lf-3**: `show bgp evpn route-type mac-ip <H1-MAC>` shows the route with
   next-hop 10.1.0.11, learned from both spines.
4. On **lf-3**: `show vxlan address-table address <H1-MAC>` (or
   `show mac address-table address <H1-MAC>`) -> `Vx1` via `10.1.0.11`.

If the MAC is local but there is no type-2: the host has not sent traffic (generate an
ARP/ping), the VLAN has no `redistribute learned` under the `vlan` in `router bgp`, or
the MAC is frozen by duplicate detection (look for `MAC_MOVE`/`DUPLICATE` log lines).

MAC mobility (VM move): the new leaf advertises with a higher MAC Mobility sequence
number.

```
show bgp evpn route-type mac-ip <mac> detail | include Mobility|seq
```

### 5.5 Type-5 (IP prefix) - external and inter-subnet routes

```
show bgp evpn route-type ip-prefix ipv4
show bgp evpn route-type ip-prefix ipv4 detail
show ip bgp vrf TENANT_A
show ip route vrf TENANT_A
show running-config | section router bgp | section vrf TENANT_A
```

On non-border leafs a default or external prefix (for example from the WAN edge)
should appear as type-5 with next-hop = border leaf VTEP (10.1.0.15 / 10.1.0.16),
two paths if both border leafs advertise it. The border leaf must
`redistribute bgp`/`network` into the EVPN address family of the VRF.

## 6. Locating a device by MAC address (narrowing down)

Goal: given a MAC (or IP), find which leaf and port it sits on.

### Step 1 - find the MAC from the IP (any leaf)

```
show ip arp vrf TENANT_A 10.20.10.50
show bgp evpn route-type mac-ip | include 10.20.10.50
```

### Step 2 - locate the MAC

On any leaf:

```
show mac address-table address aaaa.bbbb.cccc
show vxlan address-table address aaaa.bbbb.cccc
show bgp evpn route-type mac-ip aaaa.bbbb.cccc
```

* `DYNAMIC` + port (for example `Et4`) -> **this leaf**, that port. Done.
* `Vx1` + remote VTEP `10.1.0.1N` -> the host is behind leaf N (`10.1.0.1N` = ar-lf-N).
  Log in to that leaf and repeat; the port will be shown as local.

One-liner to map a VTEP IP to a switch (from the repo root, once host vars exist):
`grep -r "vtep_ip" arista/host_vars/`.

### Step 3 - confirm on the owning leaf

```
show interfaces Ethernet4 status                 ! port up?
show interfaces Ethernet4 switchport             ! access/trunk VLANs
show mac address-table address aaaa.bbbb.cccc    ! detail, move count
```

### Special MACs (do not chase these)

| MAC | What |
|---|---|
| `0044.3839.ff00` (virtual-router MAC) | Anycast gateway MAC, local on every leaf by design |
| RMAC of a VTEP (`show bgp evpn route-type ip-prefix ipv4 detail`) | Router MAC used on L3VNI routed traffic |
| Flood entry in `show vxlan flood vtep` | Head-end replication, not a host |

MAC seen on two leafs or flapping: look for a loop or duplicate address:
`show mac address-table address <mac>`, `show logging | include MAC_MOVE|DUPLICATE`.

## 7. Layer 3: VRF routing and anycast gateway

```
show ip virtual-router                           ! virtual MAC and per-SVI virtual IP state
show ip interface Vlan10                         ! SVI + virtual address
show interfaces Vlan10
show ip route vrf TENANT_A
show ip arp vrf TENANT_A
show running-config interfaces Vlan10 Vlan100
```

Checks:

* Local subnets 10.20.10/20/30.0/24 as connected; remote subnets learned via BGP/EVPN with the next-hop as the remote VTEP and the VXLAN encapsulation (`show ip route vrf TENANT_A 10.20.20.0/24` shows `Vlan100`/VXLAN).
* Same virtual IP and virtual MAC on every leaf (`show ip virtual-router`, `ip virtual-router mac-address` in the config).
* Symmetric IRB: from lf-1, a host route to a remote-subnet host (learned via type-2 with IP) points to the remote VTEP over the L3VNI.

## 8. Connectivity testing and traceroute

### 8.1 Rules that make results meaningful

* Underlay (loopback to loopback) is in the **default** VRF; tenant traffic is in `TENANT_A`. Always select the VRF explicitly with `ping vrf TENANT_A ...`.
* Source from the right interface: `source Loopback0` for underlay tests, `source Vlan10` for tenant tests.
* In VXLAN the tenant path appears as one routed hop to the remote anycast gateway; the underlay hops (spine) are encapsulated and not visible in a tenant traceroute. Test the two layers separately.

### 8.2 Leaf-to-leaf (underlay)

```
ping 10.1.0.12 source Loopback0 repeat 3
traceroute 10.1.0.12 source Loopback0          ! expect: spine -> 10.1.0.12
traceroute 10.1.0.16 source Loopback0 numeric  ! sp-1 or sp-2, ECMP-dependent
```

Cover ECMP: test each uplink explicitly with a ping from the point-to-point link
address, or vary the source/destination ports:

```
ping <spine-link-ip> source Ethernet1
ping <spine-link-ip> source Ethernet2
```

### 8.3 Leaf-to-leaf (overlay / tenant VRF)

From lf-1, via the anycast gateway on VLAN 10 to a host/SVI on another leaf:

```
ping vrf TENANT_A 10.20.20.254 source Vlan10              ! local GW, sanity
ping vrf TENANT_A 10.20.20.50 source Vlan10               ! host in other subnet behind lf-3
traceroute vrf TENANT_A 10.20.20.50 source Vlan10
ping vrf TENANT_A 10.20.10.60 source Vlan10 size 1422 df-bit   ! same-subnet host, DF set
```

Same-subnet test (L2 VNI) uses a host in VLAN 10 on a remote leaf; if it fails while
the underlay works, go to sections 4.2 and 5.3/5.4. Inter-subnet (L3 VNI) failures:
sections 4.3 and 7.

Use a host-side ping from a real endpoint when you can; pings from the switch SVI
test the control plane but not the exact host path.

### 8.4 To the external network (border leafs and beyond)

```
! On border leaf (ar-lf-5): the eBGP session in the tenant VRF
show ip bgp summary vrf TENANT_A
show ip bgp neighbors <wan-peer> vrf TENANT_A
show ip bgp neighbors <wan-peer> vrf TENANT_A advertised-routes
show ip bgp neighbors <wan-peer> vrf TENANT_A received-routes
ping vrf TENANT_A <wan-peer>
ping vrf TENANT_A <external-prefix-host> source Vlan10
traceroute vrf TENANT_A <external-ip> source Vlan10

! On a normal leaf (ar-lf-1): external reachable through the border VTEP
show ip route vrf TENANT_A <external-prefix>
traceroute vrf TENANT_A <external-ip> source Vlan10
```

Expected from lf-1 toward external: next-hop = border leaf VTEP (10.1.0.15 and/or
10.1.0.16), first visible hop is the border leaf VRF address, then the WAN edge, then
the WAN.

Reverse direction: from the external router confirm it received the fabric subnets
(10.20.10.0/24 ... 10.20.30.0/24) from the border leaf ASN and can reach the tenant
gateway.

### 8.5 Packet capture (last resort)

```
bash timeout 30 sudo tcpdump -i et1 -nn -e udp port 4789          ! VXLAN-encapsulated tenant traffic on the uplink
bash timeout 30 sudo tcpdump -i et1 -nn -vv 'udp port 4789 and host 10.1.0.14'
bash timeout 30 sudo tcpdump -i vlan10 -nn icmp                   ! decapsulated, on the SVI
bash timeout 30 sudo tcpdump -i et1 -nn tcp port 179              ! BGP
```

On EOS, `Ethernet1` is `et1` in the Linux kernel. Platforms with hardware forwarding only show
control-plane traffic to the CPU; for data-plane captures use `monitor session` (SPAN) or
`tcpdump` on a virtual platform. VNI is in the VXLAN header: confirm outer src = local VTEP, outer dst =
remote VTEP, VNI = 10010 (L2) or 10100 (L3).

## 9. Spine-specific checks

Spines hold no VNI/VXLAN state; they only relay EVPN routes. They need
`next-hop-unchanged` on the EVPN neighbors, otherwise the spine rewrites the next-hop.

```
show ip bgp summary                                  ! 6 leafs Established
show bgp evpn summary
show bgp evpn route-type imet                        ! one per leaf per VNI
show ip bgp                                          ! all loopbacks
show running-config | section address-family evpn    ! next-hop-unchanged present?
show interfaces status
```

PASS: type-2/3/5 routes from every leaf are present and re-advertised with the original
VTEP as next-hop (next-hop is the leaf loopback, not the spine). If a spine shows no
EVPN routes from a leaf but IPv4 is fine, the `l2vpn evpn` address family is not
activated on the neighbor/peer-group on one side, or `send-community extended` is missing.

## 10. Troubleshooting decision tree

```
Host A cannot reach Host B
|
+-- Same subnet (L2 VNI)?
|     +-- MAC of B visible on A's leaf via Vx1?               no -> 5.4 (type-2), 6
|     +-- Type-3 / remote VTEP list complete for the VNI?      no -> 5.3, 4.2
|     +-- Underlay ping loopback-to-loopback ok?               no -> 3, 2
|
+-- Different subnet (L3 VNI)?
|     +-- Gateway 10.20.x.254 reachable from A?                no -> 7 (virtual-router, SVI)
|     +-- Route to B's subnet / host in VRF on A's leaf?       no -> 5.4/5.5, 4.3
|     +-- L3 VNI mapped to VRF, RMACs for remote VTEP present? no -> 4.3
|
+-- External?
      +-- Border leaf eBGP to WAN Established?                 no -> 8.4
      +-- Default/prefix received and exported as type-5?      no -> 5.5
      +-- Return route on WAN edge for 10.20.x.0/24?           no -> 8.4 (advertised-routes)
```

Common faults:

| Symptom | Check |
|---|---|
| Underlay up, no EVPN routes | `address-family evpn` neighbors activated both ends, `send-community extended`; `show bgp evpn summary` |
| VNI not listed in `show vxlan vni` | `vxlan vlan N vni X` under `interface Vxlan1`, `no shutdown` on Vxlan1, VLAN exists |
| Remote VTEP count lower than expected | Missing type-3 from that leaf; check its VNI config, `vxlan flood vtep`, and its BGP |
| Type-2 present, ping fails | MTU (VXLAN adds 50 bytes), ARP in the VRF, RMAC missing, `show vxlan config-sanity` |
| L3 traffic black-holed | `vxlan vrf TENANT_A vni 10100` missing, `ip routing vrf TENANT_A` off, no RMAC |
| EVPN routes received but not installed | `ip virtual-router mac-address` mismatch, RT import/export mismatch on the VLAN/VRF in `router bgp` |
| Intermittent loss to one host | Duplicate MAC/IP, MAC mobility flapping (`show logging | include MAC_MOVE|DUPLICATE`) |
| Spine rewrites next-hop | Missing `next-hop-unchanged` on the spine EVPN neighbors |
| Config applied but no effect | `show running-config diffs`, `show configuration sessions`, `show running-config | section <block>` |
| Config lost after reload | Not saved: `show running-config diffs` non-empty, then `write memory` (or `copy running-config startup-config`) |

## 11. Running checks across the fabric with Ansible

From the repo root, once an Arista inventory group exists (group names below are
placeholders - use the ones in your inventory; the `arista.eos` collection must be
installed, see [../requirements.yml](../requirements.yml)):

```bash
# Quick sweeps
ansible arista        -m arista.eos.eos_command -a "commands='show ip bgp summary'"
ansible arista_leaf   -m arista.eos.eos_command -a "commands='show bgp evpn summary'"
ansible arista_leaf   -m arista.eos.eos_command -a "commands='show vxlan vni'"
ansible arista_leaf   -m arista.eos.eos_command -a "commands='show vxlan vtep'"

# Find a MAC across all leafs
ansible arista_leaf -m arista.eos.eos_command -a "commands='show mac address-table address aaaa.bbbb.cccc'"

# Ping every remote VTEP from each leaf
ansible arista_leaf -m arista.eos.eos_command -a "commands='ping 10.1.0.11 source Loopback0 repeat 1,ping 10.1.0.12 source Loopback0 repeat 1'"
```

The inventory must use `ansible_connection=ansible.netcommon.network_cli`,
`ansible_network_os=arista.eos.eos` and `ansible_become=yes` / `ansible_become_method=enable`
(or eAPI over `httpapi`). Use the vault option your inventory expects.

## 12. Post-change validation checklist

Print/paste into the change ticket. Mark each as PASS/FAIL.

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Interfaces up | `show interfaces status` | fabric links `connected`, MTU 9214 |
| 2 | LLDP topology | `show lldp neighbors` | matches cabling |
| 3 | Underlay BGP | `show ip bgp summary` | all Estab (leaf 2, spine 6) |
| 4 | BFD | `show bfd peers` | all Up |
| 5 | Loopback ECMP | `show ip route 10.1.0.1X/32` | 2 next-hops |
| 6 | VTEP ping | `ping 10.1.0.1X source Loopback0` | 0% loss, jumbo ok |
| 7 | EVPN AF | `show bgp evpn summary` | all Estab, pfx > 0 |
| 8 | VNIs | `show vxlan vni` | 10010/20/30 and 10100 present |
| 9 | Remote VTEPs | `show vxlan vtep` | all carrying leafs listed |
| 10 | Type-3 | `show bgp evpn route-type imet` | 1 per remote VTEP per VNI |
| 11 | Type-2 | `show bgp evpn route-type mac-ip` | test host MAC/IP learned remotely |
| 12 | L3 VNI | `show vxlan vni` | TENANT_A 10100 present, RMACs on routes |
| 13 | Anycast GW | `show ip virtual-router` | same IP/MAC on all leafs |
| 14 | Inter-subnet ping | `ping vrf TENANT_A ... source Vlan10` | success across leafs |
| 15 | External BGP (lf-5/6) | `show ip bgp summary vrf TENANT_A` | WAN peer Estab |
| 16 | External reachability | `traceroute vrf TENANT_A ...` | via border leaf to WAN |
| 17 | Logs clean | `show logging last 15 minutes` | no flaps / errors |
| 18 | VXLAN sanity | `show vxlan config-sanity` | no FAIL lines |
| 19 | No unsaved changes | `show running-config diffs` | empty (running == startup) |
| 20 | Matches intended config | `show running-config` vs the source file (13.4) | only unmanaged system lines differ |

## 13. Running configuration (`show running-config`)

EOS has no "set syntax" view. The running config is already a block of CLI commands in
the same format used to build it.

### 13.1 Full configuration

```
show running-config                     ! running (applied) config
show startup-config                     ! what loads on reboot
show running-config sanitized           ! secrets removed, safe to paste into a ticket
show running-config all                 ! including defaults
show running-config | json              ! structured, for scripting
```

### 13.2 Filtering by section

```
show running-config interfaces Loopback0                   ! loopback
show running-config interfaces Ethernet1-2                 ! fabric ports
show running-config | section router bgp                   ! all BGP
show running-config | section peer group                   ! peer-groups
show running-config | section interface Vxlan1             ! VXLAN / VLAN-VNI map
show running-config interfaces Vlan10 Vlan20 Vlan30 Vlan100  ! SVIs + virtual IPs
show running-config | section vrf instance                 ! tenant VRF
show running-config | section evpn                         ! EVPN settings
show running-config | include virtual-router               ! anycast gateway MAC
```

Applied value of a single section without the full dump: `show running-config | section <regex>`.
`show running-config | section vrf TENANT_A` lists the VRF block in `router bgp` as well.

### 13.3 Changes, history and drift

```
show running-config diffs                       ! running vs startup (empty = in sync)
show configuration sessions                     ! open/pending config sessions
show session-config diffs                       ! what a pending session would change
show session-config                             ! contents of a named session
show configuration sessions detail
write memory                                    ! save running to startup (same as copy running-config startup-config)
```

Safe change pattern for production: build the change in a config session, review the
diff, commit with a rollback timer.

```
configure session CHG1234
  ... config commands ...
  show session-config diffs
  commit timer 00:05:00        ! auto-rollback in 5 minutes unless confirmed
commit                         ! confirm
abort                          ! throw it away instead
```

Revert after a bad change: `configure replace flash:pre-change.cfg` restores a saved
configuration file. Take that checkpoint before risky changes:
`copy running-config flash:pre-change.cfg`.

### 13.4 Compare a switch with its source / Ansible-rendered config

```
! On the switch
copy running-config flash:ar-lf-1_running.cfg

! On the Ansible host
ansible arista_leaf -m arista.eos.eos_config -a "src=samples/ar-lf-1.cfg" --check --diff
ansible arista_leaf -m arista.eos.eos_command -a "commands='show running-config'" > fabric_running_config.txt
```

`--check --diff` shows what the playbook would change without applying it, which is
the Arista equivalent of the Cumulus `diff` of sample vs running.

Expected differences that are not drift: management lines (hostname, `management api`,
users, NTP/DNS, `transceiver` and `logging` lines) and ordering. Anything under
`interface Loopback0/Ethernet/Vlan`, `interface Vxlan1`, `router bgp`, `vrf instance` or
`ip virtual-router` that differs from the source is drift and should be fixed by
re-running the playbook.

## Appendix: handy command map (Cumulus -> Arista EOS)

| Need | Cumulus (NVUE / FRR) | Arista EOS |
|---|---|---|
| BGP neighbors | `nv show vrf default router bgp neighbor` / `vtysh -c "show bgp summary"` | `show ip bgp summary` |
| EVPN peers | `vtysh -c "show bgp l2vpn evpn summary"` | `show bgp evpn summary` |
| VNI list | `nv show evpn vni` | `show vxlan vni` |
| Remote VTEPs | `show evpn vni 10010` (remote VTEPs) | `show vxlan vtep` |
| Flood list (HER) | `bridge fdb show \| grep 00:00:00:00:00:00` | `show vxlan flood vtep` |
| MAC table | `nv show bridge domain br_default mac-table` / `bridge fdb show` | `show mac address-table`, `show vxlan address-table` |
| Type-2 routes | `show bgp l2vpn evpn route type macip` | `show bgp evpn route-type mac-ip` |
| Type-3 routes | `show bgp l2vpn evpn route type multicast` | `show bgp evpn route-type imet` |
| Type-5 routes | `show bgp l2vpn evpn route type prefix` | `show bgp evpn route-type ip-prefix ipv4` |
| ARP/ND | `ip neigh show vrf TENANT_A` | `show ip arp vrf TENANT_A` |
| Routes in VRF | `nv show vrf TENANT_A router rib ipv4 route` / `ip route show vrf` | `show ip route vrf TENANT_A` |
| Anycast gateway | `nv show interface vlan10 ip vrr` | `show ip virtual-router` |
| Interfaces | `nv show interface` | `show interfaces status` |
| LLDP | `nv show service lldp neighbor` | `show lldp neighbors` |
| BFD | `show bfd peers brief` | `show bfd peers` |
| VRF with ping | `ip vrf exec TENANT_A ping ...` | `ping vrf TENANT_A ...` |
| Packet capture | `tcpdump -i swp1` | `bash tcpdump -i et1` |
| Applied config | `nv config show -o commands` | `show running-config` |
| Pending / saved diff | `nv config diff`, `nv config diff applied startup` | `show session-config diffs`, `show running-config diffs` |
| Save config | `nv config save` | `write memory` |
| Consistency check | n/a | `show vxlan config-sanity` |

> Note: some commands and output formats vary between EOS releases and between
> vEOS/cEOS and hardware platforms. If one is not recognised, use `?` for the CLI
> help or `show <cmd> | json` and compare with the Cumulus column for the concept. Commands
> in this file have not been executed against the lab fabric; the values in section 0
> are placeholders until the Arista topology is added to the repo.
