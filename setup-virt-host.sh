#!/bin/bash

set -e

###############################################################################
echo "Generate ssh keys"
#ssh-keygen
ssh-keygen -f ~/.ssh/id_rsa -t rsa -N ''


###############################################################################
echo "Install packages"
dnf -y install \
	git \
	python3 \
	tmux \
	python3-setuptools \
	python3-requests

###############################################################################
echo "Install TripleO Repos"
git clone https://opendev.org/openstack/tripleo-repos.git 
cd tripleo-repos 
/usr/libexec/platform-python setup.py install
cd ~
tripleo-repos -b train current

###############################################################################
echo "Install Virtualization Host + Virtual BMC, OpenvSwitch, git etc."
dnf -y groupinstall 'Virtualization Host'
dnf -y install \
	python3-virtualbmc \
	openvswitch \
	NetworkManager-ovs \
	virt-install \
	libguestfs-tools \
	libguestfs-xfs


###############################################################################
echo "Start openvswitch"
systemctl enable openvswitch.service
systemctl start openvswitch.service


###############################################################################
echo "Enable nested virtualization."
cat << EOF > /etc/modprobe.d/kvm_intel.conf
options kvm-intel nested=1
options kvm-intel enable_shadow_vmcs=1
options kvm-intel enable_apicv=1
options kvm-intel ept=1
EOF

modprobe -r kvm_intel
modprobe kvm_intel

###############################################################################
echo "Set up openvswitch bridge and interfaces"
nmcli c add type ovs-bridge \
   conn.interface br-libvirtovs \
   con-name br-libvirtovs
nmcli c add type ovs-port \
   conn.interface br-libvirtovs \
   master br-libvirtovs con-name ovs-port-br-libvirtovs
nmcli c add type ovs-interface \
   slave-type ovs-port \
   conn.interface br-libvirtovs \
   master ovs-port-br-libvirtovs \
   con-name ovs-if-br-libvirtovs \
   ipv6.method static \
   ipv6.address 2620:dead:beef:5::f:ff/64
nmcli c add type ovs-port \
   conn.interface ctlplane \
   master br-libvirtovs \
   ovs-port.tag 1 \
   con-name ovs-port-libvirtovs
nmcli c add type ovs-interface \
   slave-type ovs-port \
   conn.interface libvirtovs \
   master ovs-port-libvirtovs \
   con-name ovs-if-libvirtovs \
   ipv6.method static \
   ipv6.address 2620:dead:beef:5::1:ff/64

systemctl restart NetworkManager


###############################################################################
echo "Create libvirt network"
systemctl restart libvirtd
cat << EOF > /tmp/virsh-net-libvirtovs.xml
<network>
  <name>libvirtovs</name>
  <forward mode='bridge'/>
  <bridge name='br-libvirtovs'/>
  <virtualport type='openvswitch'/>
  <portgroup name='ctlplane' default='yes'>
    <vlan>
      <tag id='1'/>
    </vlan>
  </portgroup>
  <portgroup name='external'>
    <vlan trunk='yes'>
      <tag id='10'/>
      <tag id='20'/>
      <tag id='30'/>
      <tag id='40'/>
      <tag id='50'/>
      <tag id='60'/>
      <tag id='70'/>
    </vlan>
  </portgroup>
  <portgroup name='management'>
    <vlan trunk='yes'>
      <tag id='110'/>
      <tag id='120'/>
      <tag id='130'/>
      <tag id='140'/>
      <tag id='150'/>
      <tag id='160'/>
      <tag id='170'/>
    </vlan>
  </portgroup>
</network>
EOF
virsh net-define /tmp/virsh-net-libvirtovs.xml
virsh net-autostart libvirtovs
virsh net-start libvirtovs

###############################################################################
echo "Create undercloud VM."
cd /var/lib/libvirt/images/
# Download and decompress CentOS Cloud image
curl -o CentOS-8-GenericCloud.qcow2 https://cloud.centos.org/centos/8/x86_64/images/CentOS-8-GenericCloud-8.2.2004-20200611.2.x86_64.qcow2

# Create a new image for undercloud
qemu-img create -f qcow2 undercloud.qcow2 50G

# Clone and resize the CentOS cloud image to our 40G undercloud image
virt-resize --expand /dev/sda1 CentOS-8-GenericCloud.qcow2 undercloud.qcow2

# Set the root password
virt-customize -a undercloud.qcow2 --root-password password:Redhat01

# Create config drive

mkdir -p /tmp/cloud-init-data/
cat << EOF > /tmp/cloud-init-data/meta-data
instance-id: undercloud-instance-id
local-hostname: undercloud.example.com
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
EOF
cat << EOF > /tmp/cloud-init-data/user-data
#cloud-config
disable_root: false
ssh_authorized_keys:
  - $(cat ~/.ssh/id_rsa.pub)
EOF

genisoimage -o undercloud-config.iso -V cidata -r \
  -J /tmp/cloud-init-data/meta-data /tmp/cloud-init-data/user-data

# Launch the undercloud vm
virt-install --ram 16384 --vcpus 4 --os-variant centos7.0 \
--disk path=/var/lib/libvirt/images/undercloud.qcow2,device=disk,bus=virtio,format=qcow2 \
--disk path=/var/lib/libvirt/images/undercloud-config.iso,device=cdrom \
--import --noautoconsole --vnc \
--network network:default \
--network network:libvirtovs,portgroup=ctlplane \
--name undercloud

cd ~

###############################################################################
echo "Create disks for bms."
qemu-img create -f qcow2 -o preallocation=metadata /var/lib/libvirt/images/bm01.qcow2 50G
qemu-img create -f qcow2 -o preallocation=metadata /var/lib/libvirt/images/bm02.qcow2 50G

###############################################################################
echo "Create libvirt vms"
cat << EOF > /tmp/bm01.xml
<domain type="kvm">
  <name>bm01</name>
  <memory>4194304</memory>
  <currentMemory>4194304</currentMemory>
  <vcpu>2</vcpu>
  <os>
    <type arch="x86_64">hvm</type>
    <boot dev="hd"/>
  </os>
  <cpu mode="host-model"/>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/var/lib/libvirt/images/bm01.qcow2"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="libvirtovs" portgroup="ctlplane"/>
      <model type="virtio"/>
    </interface>
    <interface type="network">
      <source network="libvirtovs" portgroup="external"/>
      <model type="virtio"/>
    </interface>
    <interface type="network">
      <source network="libvirtovs" portgroup="management"/>
      <model type="virtio"/>
    </interface>
    <graphics type="vnc" port="-1" autoport="yes" listen="127.0.0.1">
      <listen type="address" address="127.0.0.1"/>
    </graphics>
  </devices>
</domain>
EOF
virsh define --file /tmp/bm01.xml

cat << EOF > /tmp/bm02.xml
<domain type="kvm">
  <name>bm02</name>
  <memory>4194304</memory>
  <currentMemory>4194304</currentMemory>
  <vcpu>2</vcpu>
  <os>
    <type arch="x86_64">hvm</type>
    <boot dev="hd"/>
  </os>
  <cpu mode="host-model"/>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/var/lib/libvirt/images/bm02.qcow2"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="libvirtovs" portgroup="ctlplane"/>
      <model type="virtio"/>
    </interface>
    <interface type="network">
      <source network="libvirtovs" portgroup="external"/>
      <model type="virtio"/>
    </interface>
    <interface type="network">
      <source network="libvirtovs" portgroup="management"/>
      <model type="virtio"/>
    </interface>
    <graphics type="vnc" port="-1" autoport="yes" listen="127.0.0.1">
      <listen type="address" address="127.0.0.1"/>
    </graphics>
  </devices>
</domain>
EOF
virsh define --file /tmp/bm02.xml

###############################################################################
echo "Configure virtual BMC for overcloud nodes."
vbmc add --username admin --password password --port 6240 bm01
vbmc add --username admin --password password --port 6241 bm02
vbmc start bm01
vbmc start bm02


###############################################################################
echo "Generate instackenv.json"
/usr/libexec/platform-python -c "
import json
import libvirt
from xml.dom import minidom

NODE_PREFIX = 'bm'
VBMC_HOST = '192.168.124.1'
VBMC_USER = 'admin'
VBMC_PASSWORD = 'password'

VBMC_PORT_MAP = {'bm01': 6240, 'bm02': 6241,}

instackenv = {'nodes': []}
nodes = instackenv['nodes']
data_format = ('\"pm_type\": \"ipmi\", ' 
               '\"mac\": [\"{mac}\"], ' 
               '\"pm_user\": \"' + VBMC_USER + '\", ' 
               '\"pm_password\": \"' + VBMC_PASSWORD + '\", ' 
               '\"pm_addr\": \"' + VBMC_HOST + '\", ' 
               '\"pm_port\": \"{vbmc_port}\", ' 
               '\"name\": \"{domain_name}\"')


conn = libvirt.openReadOnly(None)
domains = conn.listAllDomains(0)
for domain in domains:
    if domain.name().startswith(NODE_PREFIX):
        raw_xml = domain.XMLDesc()
        xml = minidom.parseString(raw_xml)
        mac = xml.getElementsByTagName(
	  'interface')[0].getElementsByTagName(
	  'mac')[0].attributes['address'].value
        data = data_format.format(mac=mac,
                                  vbmc_port=VBMC_PORT_MAP[domain.name()],
                                  domain_name=domain.name())
        nodes.append(json.loads('{' + data + '}'))

print(json.dumps(instackenv, indent=4,  sort_keys=True))
" > instackenv.json

###############################################################################
echo "UNDERCLOUD IP:"
virsh domifaddr undercloud

