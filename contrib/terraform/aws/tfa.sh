#!/bin/bash

#
# This script provisions the AWS infrastructure using Terraform.
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

rm -rf \
  $KUBESPRAY_INSTALL_DIR/artifacts \
  $INVENTORY/hosts \
  $KUBESPRAY_INSTALL_DIR/ssh-bastion.conf

pushd $KUBESPRAY_INSTALL_DIR/contrib/terraform/aws > /dev/null

terraform init

terraform apply \
    --var-file=credentials.tfvars \
    --auto-approve

popd > /dev/null
