#!/bin/bash

kubectl delete \
    -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/aws/deploy.yaml

terraform destroy --var-file=credentials.tfvars --auto-approve
