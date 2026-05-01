# Multisite-Multivendor-Vxlan-Fabric
Ansible and Python program files for deploying Vxlan Fabric and Telemetry 

This project will help in deploying a Multisite Multivendor Vxlan BGP-EVPN on a GNS3 platform 

The project will have a Vxlan fabric running on several different platforms with individual fabric running on different vendor platforms

Platforms Listed below 

1.Cisco NXOS 9K  
2.Arista EOS
3.Sonic NOS

All the above mentioned platforms will have a datacenter fabric running Vxlan EVPN 

All the different fabric will be interconnected over an MPLS Routing backbone running on Cisco IOS platform 

Phase-1 

Phase-1 will be to built Vxlan fabric on all the different platform and advertising the different overlay networks to the routing backbone

Phase-2

To deploy an MPLS backbone on Cisco IOS platform with OSPF underlay and BGP vpnv4 overlay 

Advertise the learned routes from the different VXlan fabric between each other using BGP vnpv4 and Route-Target

Phase-3

Define a Multisite network which is supported between 2 different Vxlan fabrics using BGP underlay and testing failover.