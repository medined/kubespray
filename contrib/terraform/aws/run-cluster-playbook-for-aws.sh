#!/bin/bash

#
# This script connects to the first bastion server in the inventory file.
#
# CONFIGURATION IS NEEDED.
#
# * Set PKI_PRIVATE_PEM to the location of your PEM file used when creating the cluster.

# * Set KUBESPRAY_INSTALL_DIR to the root directory of the KubeSpray project. This variable
#   is used so that $KUBESPRAY_INSTALL_DIR/contrib/terraform/aws can be put into your path 
#   allowing this script to be run from any directory.
#

if [ -z $PKI_PRIVATE_PEM ]; then
    echo "Missing Environment Variable: PKI_PRIVATE_PEM"
    echo "  This variable should point to the PEM file for the BASTION server."
fi

if [ -z $KUBESPRAY_INSTALL_DIR ]; then
    echo "Missing Environment Variable: KUBESPRAY_INSTALL_DIR"
    echo "  This variable should point the root of the Kubespray project; where the LICENSE file is."
fi

INVENTORY="$KUBESPRAY_INSTALL_DIR/inventory/hosts"

if [ ! -f $INVENTORY ]; then
    echo "Missing file: $INVENTORY"
    echo "  This file should be created by the Terraform apply command."
fi

ssh-add $PKI_PRIVATE_PEM

pushd $KUBESPRAY_INSTALL_DIR > /dev/null

time ansible-playbook \
  -vvvvv \
  -i $INVENTORY \
  ./cluster.yml \
  -e ansible_user=centos \
  -e cloud_provider=aws \
  -e bootstrap_os=centos \
  --become \
  --become-user=root \
  --flush-cache \
  -e ansible_ssh_private_key_file=$PKI_PRIVATE_PEM \
  | tee kubespray-cluster-$(date "+%Y-%m-%d_%H:%M").log

CONTROLLER_HOST_NAME=$(cat $INVENTORY | grep "\[kube-master\]" -A 1 | tail -n 1)
CONTROLLER_IP=$(cat $INVENTORY | grep $CONTROLLER_HOST_NAME | grep ansible_host | cut -d'=' -f2)
LB_HOST=$(cat $INVENTORY | grep apiserver_loadbalancer_domain_name | cut -d'"' -f2)

cd inventory/artifacts
cp admin.conf admin.conf.original
sed -i "s^server:.*^server: https://$LB_HOST:6443^" admin.conf

echo "------------------"
./kubectl --kubeconfig=admin.conf get nodes

./kubectl --kubeconfig=admin.conf apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/aws/deploy.yaml

echo "------------------"
echo "Run the following commands to configure kubectl to use the new cluster"
echo "  rm $HOME/.kube/config"
echo "  ln -s $KUBESPRAY_INSTALL_DIR/inventory/artifacts/admin.conf $HOME/.kube/config"
echo

popd > /dev/null
