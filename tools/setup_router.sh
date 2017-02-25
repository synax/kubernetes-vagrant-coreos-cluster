#!/bin/vbash

source /opt/vyatta/etc/functions/script-template

# Add desctiption for NAT and External Interface
set interfaces ethernet eth0 description 'NAT'
set interfaces ethernet eth1 description 'External'

#Configure vLans for private network
set interfaces ethernet eth2 address __BASE_IP__.1/24
set interfaces ethernet eth2 description 'Untagged'

#Enable DNS forwarding for private network
#set service dns forwarding system
#set service dns forwarding cache-size 0

# Home
set system gateway-address __GATEWAY_IP__
set system name-server __DNS_IP__

# Mobile Hotspot
# set system gateway-address 172.20.10.1
# set system name-server 172.20.10.1

set service dns forwarding listen-on eth2
set service dns forwarding listen-on eth2.1

#Configure NAT
set nat source rule 100 outbound-interface eth1
#set nat source rule 100 source address 172.18.0.0/16
set nat source rule 100 translation address masquerade

#Configure static route
#set protocols static route 0.0.0.0/0 next-hop 192.168.1.1 distance '1'
#set protocols static route 172.18.0.0/16 next-hop 0.0.0.0

commit
save
