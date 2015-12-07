#!/bin/sh

for vm in ipa openstack ; do
    sudo virsh destroy $vm
    sudo virsh undefine --remove-all-storage $vm
done

for img in ipa.qcow2 ipa-cidata.iso openstack.qcow2 openstack-cidata.iso; do
    rm -f /var/lib/libvirt/images/$img
done

virsh net-destroy oslocaltest
virsh net-undefine oslocaltest
