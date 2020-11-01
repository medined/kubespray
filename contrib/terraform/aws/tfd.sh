#!/bin/bash

#
# This script destroys the Kubernetes cluster.
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

kubectl delete \
    -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/aws/deploy.yaml

pushd $KUBESPRAY_INSTALL_DIR/contrib/terraform/aws > /dev/null

terraform destroy \
    --var-file=credentials.tfvars \
    --auto-approve

popd > /dev/null
