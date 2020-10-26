#!/bin/bash
dnf install -y \
	git \
	python3-virtualenv \
	vim-enhanced \
	tmux \
	libselinux-python3 \
	libvirt-python3 \
	python3-lxml

sudo dnf install -y https://trunk.rdoproject.org/centos8/component/tripleo/current/python3-tripleo-repos-0.1.1-0.20200909062930.1c4a717.el8.noarch.rpm

sudo -E tripleo-repos -b train current

ssh-keygen -f ~/.ssh/id_rsa -t rsa -N ''

ssh-copy-id root@localhost

DEPLOY_HOST=infrared-hypervisor.lab.example.com
LOGDIR=/tmp/deploy.logs
STACK_COMP="undercloud:1,controller:1"
BASE_IMAGE=CentOS-8-GenericCloud-8.2.2004-20200611.2.x86_64.qcow2
IMG_URL=http://192.168.122.1/

IR_HOME=`mktemp -d -p /tmp -t IPV6_POC.XXXXXXXXXX`
cd ${IR_HOME}

git clone https://github.com/redhat-openstack/infrared.git ${IR_HOME}
cd ${IR_HOME}/infrared
git fetch "https://review.gerrithub.io/redhat-openstack/infrared" refs/changes/73/504773/5 && git checkout -b change-504773-5 FETCH_HEAD
cd ${IR_HOME}

mkdir ${IR_HOME}/tmp

virtualenv ${IR_HOME}/.venv
echo "export IR_HOME=${IR_HOME}" >> ${IR_HOME}/.venv/bin/activate
source ${IR_HOME}/.venv/bin/activate
pip install -U pip |tee -ia ${LOGDIR}/${TS}_pip_updates.log
pip install -U setuptools |tee -ia ${LOGDIR}/${TS}_pip_updates.log

pip install .  |tee -ia ${LOGDIR}/${TS}_pip_updates.log

export TMPDIR=${IR_HOME}/tmp

cp infrared.cfg.example infrared.cfg
infrared plugin add all |tee -ia ${LOGDIR}/${TS}_pip_updates.log
cat << EOF > ansible.cfg
[defaults]
host_key_checking = False
forks = 500
pipelining = True
timeout = 30
force_color = 1
roles_path = infrared/common/roles
library = infrared/common/library
filter_plugins = infrared/common/filter_plugins
callback_plugins = infrared/common/callback_plugins
callback_whitelist = timer,profile_tasks,junit_report

[ssh_connection]
control_path = ${IR_HOME}/.venv/%%h-%%r
EOF

# reload the virtual env just to be sure
source ${IR_HOME}/.venv/bin/activate

infrared virsh \
    -o cleanup.yml \
    --host-address ${DEPLOY_HOST} \
    --host-key /root/.ssh/id_rsa \
    --cleanup yes  |tee -ia ${LOGDIR}/${TS}_virsh_cleanup.log

# source /tmp/work_scripts/current_env
source ${IR_HOME}/.venv/bin/activate
cd ${IR_HOME}

infrared virsh \
    -o provision.yml \
    --topology-nodes  ${STACK_COMP} \
    --topology-network 3_net_openvswitch \
    --host-address ${DEPLOY_HOST} \
    --host-key /root/.ssh/id_rsa \
    --host-memory-overcommit True \
    --image-url  ${IMG_URL}/${BASE_IMAGE} \
    --collect-ansible-facts False \
    -e override.undercloud.disks.disk1.size=50G \
    -e override.undercloud.memory=8192 \
    -e override.undercloud.os.variant=rhel8-unknown \
    -e override.controller.cpu=2 \
    -e override.controller.memory=4096 \
    -e override.controller.disks.disk1.size=20G \
    -e override.controller.os.variant=rhel8-unknown \
    |tee -ia ${LOGDIR}/${TS}_virsh_provsion.log

