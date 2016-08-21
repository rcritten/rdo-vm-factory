#!/bin/sh

set -o errexit
# Source our IPA config for IPA settings
SOURCE_DIR=${SOURCE_DIR:-/mnt}

# global network config
. $SOURCE_DIR/global.conf

. $SOURCE_DIR/ipa.conf

yum -y install python-novajoin

# Save the IPA FQDN and IP for later use
IPA_FQDN=$VM_FQDN
IPA_IP=$VM_IP
IPA_DOMAIN=$VM_DOMAIN

# Source our config for OpenStack settings
. $SOURCE_DIR/openstack.conf

# cloud-config data
cp $SOURCE_DIR/cloud-config.json /etc/nova
openstack-config --set /etc/nova/nova.conf DEFAULT vendordata_jsonfile_path /etc/nova/cloud-config.json

# TEMP: Apply vendordata patch. nova is restarted later
pushd /usr/lib/python2.7/site-packages
patch -p1 < $SOURCE_DIR/0001-New-style-vendordata-support.patch
popd

# put nova in debug mode
openstack-config --set /etc/nova/nova.conf DEFAULT debug True
# use kvm
openstack-config --set /etc/nova/nova.conf DEFAULT virt_type kvm
# set the default domain to the IPA domain
openstack-config --set /etc/nova/nova.conf DEFAULT dhcp_domain $IPA_DOMAIN

# Configure the dynamic metadata provider
openstack-config --set /etc/nova/nova.conf DEFAULT vendordata_providers "StaticJSON, DynamicJSON"
openstack-config --set /etc/nova/nova.conf DEFAULT vendordata_dynamic_targets 'join@http://127.0.0.1:9999/v1/'
openstack-config --set /etc/nova/nova.conf DEFAULT vendordata_dynamic_read_timeout 30 

# Enable notifications
openstack-config --set /etc/nova/nova.conf DEFAULT notification_driver messaging
openstack-config --set /etc/nova/nova.conf DEFAULT notification_topic notifications
openstack-config --set /etc/nova/nova.conf DEFAULT notify_on_state_change vm_state

. /root/keystonerc_admin

# Setup novajoin
KEYSTONE_AUTH=`grep "^auth_uri" /etc/nova/nova.conf | cut -d= -f2 | sed 's/ //g'`
KEYSTONE_IDENTITY=`grep "^identity_uri" /etc/nova/nova.conf | cut -d= -f2 | sed 's/ //g'`
NOVA_PASSWORD=`grep "^admin_password" /etc/nova/nova.conf | cut -d= -f2 | sed 's/ //g'`
/usr/sbin/novajoin-install --principal admin --password "$IPA_PASSWORD" --keystone-auth="$KEYSTONE_AUTH" --keystone-identity="$KEYSTONE_IDENTITY" --nova-password="$NOVA_PASSWORD"

systemctl start novajoin-server.service
systemctl start novajoin-notify.service

# If a SSH key was provided, create a keypair in openstack
if [ -e /root/.ssh/id_rsa.pub ]; then
    openstack keypair create --public-key /root/.ssh/id_rsa.pub osuser
fi

# need a real el7 image in order to run ipa-client-install
#if [ -n "$USE_CENTOS" ] ; then
    openstack image create el7 --file $SOURCE_DIR/CentOS-7-x86_64-GenericCloud.qcow2
#else
#    openstack image create el7 --file $SOURCE_DIR/rhel-guest-image-7.1-20150224.0.x86_64.qcow2
#fi

# tell dhcp agent which DNS servers to use - use IPA first
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dnsmasq_dns_servers $IPA_IP,$VM_IP

if [ -n "$USE_PROVIDER_NETWORK" ] ; then
    cat > /etc/sysconfig/network-scripts/ifcfg-br-ex <<EOF
DEVICE=br-ex
DEVICETYPE=ovs
TYPE=OVSBridge
MACADDR=$VM_MAC
BOOTPROTO=static
IPADDR=$VM_IP
NETMASK=$VM_NETWORK_MASK
GATEWAY=$VM_NETWORK_GW
DNS1=$IPA_IP
DNS2=$VM_NETWORK_GW
ONBOOT=yes
NM_CONTROLLED=no
EOF

    cat > /etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
DEVICE=eth0
HWADDR=$VM_MAC
TYPE=OVSPort
DEVICETYPE=ovs
OVS_BRIDGE=br-ex
ONBOOT=yes
NM_CONTROLLED=no
EOF
    systemctl restart network.service
    openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings extnet:br-ex
    openstack-config --set /etc/neutron/plugin.ini ml2 type_drivers vxlan,flat,vlan

fi

# set up ip forwarding and NATing so the new server can access the outside network
echo set up ipv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sed -i "/net.ipv4.ip_forward = 0/s//net.ipv4.ip_forward = 1/" /etc/sysctl.conf && sysctl -p || echo problem
if [ -n "$VM_NODHCP" ] ; then
    echo set up NATing
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -I FORWARD 1 -j ACCEPT
    iptables-save > /etc/sysconfig/iptables
fi

# restart nova and neutron and networking
openstack-service restart nova
openstack-service restart neutron

if [ -n "$USE_PROVIDER_NETWORK" ] ; then
    pubnet=public
    privnet=private
    neutron net-create $pubnet --provider:network_type flat --provider:physical_network extnet \
            --router:external --shared
    neutron subnet-create --name public_subnet --enable_dhcp=False \
            --allocation-pool=start=${VM_FLOAT_START},end=${VM_FLOAT_END} \
            --gateway=$VM_NETWORK_GW $pubnet $VM_EXT_NETWORK
    neutron router-create router1
    neutron net-create $privnet
    neutron subnet-create --name private_subnet $privnet $VM_INT_NETWORK
    neutron router-interface-add router1 private_subnet
    neutron net-show $pubnet
    neutron net-show $privnet
    neutron subnet-show public_subnet
    neutron subnet-show private_subnet
    neutron port-list --long
    neutron router-show router1
    ip a
    route
fi

SEC_GRP_IDS=$(openstack security group list | awk '/ default / {print $2}')
PUB_NET=$(openstack network list | awk '/ public / {print $2}')
PRIV_NET=$(openstack network list | awk '/ private / {print $2}')
ROUTER_ID=$(openstack router list | awk ' /router1/ {print $2}')
# Set the Neutron gateway for router
neutron router-gateway-set $ROUTER_ID $PUB_NET

# route private network through public network
ip route replace $VM_INT_NETWORK via $VM_EXT_ROUTE
# make route persistent
cat > /etc/sysconfig/network-scripts/route-br-ex <<EOF
GATEWAY0=$VM_EXT_ROUTE
NETMASK0=$VM_INT_NETMASK
ADDRESS0=$VM_INT_NETADDR
EOF

#Add security group rules to enable ping and ssh:
for secgrpid in $SEC_GRP_IDS ; do
    project=$(openstack security group show $secgrpid | awk '/ project_id / {print $4}')
    openstack security group rule create --protocol icmp \
            --ingress --src-ip 0.0.0.0/0 $secgrpid \
            --project $project
    openstack security group rule create --protocol tcp  \
            --dst-port 22 --ingress $secgrpid \
            --project $project
done

BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}

myping() {
    ii=$2
    while [ $ii -gt 0 ] ; do
        if ping -q -W1 -c1 -n $1 ; then
            break
        fi
        ii=`expr $ii - 1`
        sleep 1
    done
    if [ $ii = 0 ] ; then
        echo $LINENO "server did not respond to ping $1"
        return 1
    fi
    return 0
}

# get private network id
netid=`openstack network list|awk '/ private / {print $2}'`
if [ -z "$netid" ] ; then
    netid=`nova net-list|awk '/ novanetwork / {print $2}'`
fi
if [ -z "$netid" ] ; then
    echo Error: could not find private network
    openstack network list --long
    nova net-list
    neutron subnet-list
    exit 1
fi

if [ -n "$DEMO_SETUP" ] ; then
    echo openstack server create el7 --flavor m1.small --image el7 --security-group default \
         --nic net-id=$netid --property ipaclass=app_server
    exit 0
fi

if [ -e /root/.ssh/id_rsa.pub ]; then
    OPT_CMD=" --key-name osuser"
else
    OPT_CMD=""
fi

VM_UUID=$(openstack server create el7 --flavor m1.small --image el7 --security-group default --nic net-id=$netid --property ipaclass=app_server --property ipa_enroll=True $OPT_CMD | awk '/ id / {print $4}')

ii=$BOOT_TIMEOUT
while [ $ii -gt 0 ] ; do
    if openstack server show el7|grep ACTIVE ; then
        break
    fi
    if openstack server show el7|grep ERROR ; then
        echo could not create server
        openstack server show el7
        exit 1
    fi
    ii=`expr $ii - 1`
done

if [ $ii = 0 ] ; then
    echo $LINENO server was not active after $BOOT_TIMEOUT seconds
    openstack server show el7
    exit 1
fi

VM_IP=$(openstack server show el7 | sed -n '/ addresses / { s/^.*addresses.*private=\([0-9.][0-9.]*\).*$/\1/; p; q }')

# With OSP-10 I can't seem to ping the private network?
#if ! myping $VM_IP $BOOT_TIMEOUT ; then
#    echo $LINENO "server did not respond to ping $VM_IP"
#    exit 1
#fi

PORTID=$(neutron port-list --device-id $VM_UUID | awk "/$VM_IP/ {print \$2}")
FIPID=$(neutron floatingip-create public | awk '/ id / {print $4}')
neutron floatingip-associate $FIPID $PORTID
FLOATING_IP=$(neutron floatingip-list | awk "/$VM_IP/ {print \$6}")
FLOATID=$(neutron floatingip-list | awk "/$VM_IP/ {print \$2}")

if ! myping $FLOATING_IP $BOOT_TIMEOUT ; then
    echo $LINENO "server did not respond to ping $FLOATING_IP"
    exit 1
fi
