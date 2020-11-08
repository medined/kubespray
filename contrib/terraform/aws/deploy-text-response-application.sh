#!/bin/bash

#
# This script deploys a text responder application. It has no practical value
# other than proving an application can be deployed. Consider it a smoke test
# for your cluster.
#

#
# CONFIGURATION
#
# Find the service endpoint on https://docs.aws.amazon.com/general/latest/gr/elb.html. It
# will be different for each Region. Ingress is using a network load balancer so look in 
# that column. Note that this value is not the same as the Hosted Zone Id found on the 
# Route53 pages. This value is set because it should not change.
#
HOSTED_ZONE_ID="Z26RNL4JYFTOTI"

#
# INPUT VALIDATION
#
if [ -z $K8S_DOMAIN_NAME ]; then
    echo "Missing Environment Variable: K8S_DOMAIN_NAME"
    exit 1
fi

if [ -z $TEXT_RESPONDER_SUBDOMAIN_NAME ]; then
    echo "Missing Environment Variable: TEXT_RESPONDER_SUBDOMAIN_NAME"
    exit 1
fi

if [ -z $ACME_EMAIL ]; then
    echo "Missing Environment Variable: ACME_EMAIL"
    echo "  This email is used for getting certificates from Let's Encrypt."
    exit 1
fi


#
# Are we in the right directory?
#
if [ ! -f yaml-text-responder-application.yaml ]; then
    echo "Missing YAML file: yaml-text-responder-application.yaml"
    echo "  Please change to the directory with that file: contrib/terraform/aws"
    exit 1
fi

FQDN="$TEXT_RESPONDER_SUBDOMAIN_NAME.$K8S_DOMAIN_NAME"

INGRESS_LB=$(kubectl \
  -n ingress-nginx \
  get service ingress-nginx-controller \
  --output=jsonpath="{.status.loadBalancer.ingress[0].hostname}"
)

if [ -z $INGRESS_LB ]; then
    echo "Missing Load Balancer for 'ingress-nginx-controller' service."
    exit 1
fi

HOSTED_ZONE_PATH=$(aws route53 list-hosted-zones-by-name \
  --dns-name $K8S_DOMAIN_NAME \
  --query "HostedZones[0].Id" \
  --output text)

HOSTED_ZONE_ID_FROM_R53=$(echo $HOSTED_ZONE_PATH | cut -d'/' -f3)

cat <<EOF > /tmp/change-resource-record-set.json
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$FQDN",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "$HOSTED_ZONE_ID",
                    "EvaluateTargetHealth": true,
                    "DNSName": "${INGRESS_LB}."
                }
            }
        }
    ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID_FROM_R53 \
  --change-batch file:///tmp/change-resource-record-set.json

rm /tmp/change-resource-record-set.json

#
# When I try to combine the YAML below with the YAML above, I 
# get a syntax error.
#

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1beta1
kind: ClusterIssuer
metadata:
    name: letsencrypt-staging
spec:
    acme:
        email: $ACME_EMAIL
        server: https://acme-staging-v02.api.letsencrypt.org/directory
        privateKeySecretRef:
            name: letsencrypt-staging-secret
        solvers:
        - http01:
            ingress:
                class: nginx
---
apiVersion: cert-manager.io/v1beta1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    email: $ACME_EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production-secret
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

#
# Variable are used to make the script re-usable.
#

APP_NAME="text-responder"
NAMESPACE_NAME="text-responder"

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE_NAME
  labels:
    name: $APP_NAME
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE_NAME
spec:
  selector:
    matchLabels:
      app: $APP_NAME
  replicas: 1
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
      - name: $APP_NAME
        image: hashicorp/http-echo
        args:
        - "-text=silverargint"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE_NAME
spec:
  ports:
  - port: 80
    targetPort: 5678
  selector:
    app: $APP_NAME
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE_NAME
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  tls:
  - hosts:
    - $FQDN
    secretName: $APP_NAME-tls
  rules:
  - host: $FQDN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $APP_NAME
            port:
              number: 80
EOF

echo "The text-responder application has been deployed."
echo 
echo "Below is the result of: curl https://$FQDN"
echo
curl https://$FQDN
