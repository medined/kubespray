#!/bin/bash

#
# This script runs the five kinds of KubeBench tests.
#
# CONFIGURATION IS NEEDED.
#
# * Set KUBESPRAY_INSTALL_DIR to the root directory of the KubeSpray project. This variable
#   is used so that $KUBESPRAY_INSTALL_DIR/contrib/terraform/aws can be put into your path 
#   allowing this script to be run from any directory.
#

if [ -z $KUBESPRAY_INSTALL_DIR ]; then
    echo "Missing Environment Variable: KUBESPRAY_INSTALL_DIR"
    echo "  This variable should point the root of the Kubespray project; where the LICENSE file is."
fi

INVENTORY="$KUBESPRAY_INSTALL_DIR/inventory/hosts"

if [ ! -f $INVENTORY ]; then
    echo "Missing file: $INVENTORY"
    echo "  This file should be created by the Terraform apply command."
fi

CONTROLLER_HOST_NAME=$(cat $INVENTORY | grep "\[kube-master\]" -A 1 | tail -n 1)
CONTROLLER_IP=$(cat $INVENTORY | grep $CONTROLLER_HOST_NAME | grep ansible_host | cut -d'=' -f2)

ETCD_HOST_NAME=$(cat $INVENTORY | grep "\[etcd\]" -A 1 | tail -n 1)
ETCD_IP=$(cat $INVENTORY | grep $ETCD_HOST_NAME | grep ansible_host | cut -d'=' -f2)

WORKER_HOST_NAME=$(cat $INVENTORY | grep "\[kube-node\]" -A 1 | tail -n 1)
WORKER_IP=$(cat $INVENTORY | grep $WORKER_HOST_NAME | grep ansible_host | cut -d'=' -f2)

pushd $KUBESPRAY_INSTALL_DIR

ssh -F ssh-bastion.conf centos@$CONTROLLER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    --volume /var/lib/kubelet:/var/lib/kubelet:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets master \
    | tee kubebench-01-master-findings.log

ssh -F ssh-bastion.conf centos@$ETCD_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets etcd \
    | tee kubebench-02-etcd-findings.log

ssh -F ssh-bastion.conf centos@$CONTROLLER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets controlplane \
    | tee kubebench-03-controlplane-findings.log

ssh -F ssh-bastion.conf centos@$WORKER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /var/lib/kubelet:/var/lib/kubelet:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets node \
    | tee kubebench-04-worker-findings.log

ssh -F ssh-bastion.conf centos@$CONTROLLER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets policies \
    | tee kubebench-05-policies-findings.log


PASS_COUNT=$(cat kubebench-*.log | grep "^\[" | grep PASS | wc -l)
WARN_COUNT=$(cat kubebench-*.log | grep "^\[" | grep WARN | wc -l)
FAIL_COUNT=$(cat kubebench-*.log | grep "^\[" | grep FAIL | wc -l)

echo " PASS: $PASS_COUNT"
echo " WARN: $WARN_COUNT"
echo " FAIL: $FAIL_COUNT"

popd
