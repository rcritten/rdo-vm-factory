#!/bin/sh

for vm in ipa openstack ; do
    sudo virsh destroy $vm
    sudo virsh undefine --remove-all-storage $vm
done
