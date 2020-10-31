# Document Changes From Official KubeSpray Project

* Encryption At Rest is enabled.

## Prelimary Work You Must Do!

* Read https://medined.github.io/kubernetes/kubespray/encryption/ansible/add-aws-encryption-provider-to-kubespray/ to learn about creating an encryption provider image or just use
`medined/aws-encryption-provider`. Pay special attention to the section about KEY keys.

* Create an EC2 key pair.

* Export the following environment variables. I use `direnv`. Make sure to change the KMS key and PKI private pem file information.

```
export AWS_DEFAULT_REGION=us-east-1
export AWS_PROFILE="ic1"
export CLUSTER="flooper"
export IMAGE_NAME="medined/aws-encryption-provider"
export KEY_ID="6a2e5bff-fd5b-4fe6-9394-c4facdc98ece"
export KEY_ARN="arn:aws:kms:us-east-1:506315921615:key/6a2e5bff-fd5b-4fe6-9394-c4facdc98ece"
export PKI_PRIVATE_PEM=/data/home/medined/Downloads/pem/davidm.xyz.pem
```

* After cloning this repository, make sure to activate your Python virtual environment. I use `direnv` for this as well.

```
pip install -r requirements.txt
```

* In `contrib/terraform/aws/terraform.tfvars`, set variables as needed. Note that the inventory file will be created a few levels up in the directory tree. Make sure that the CIDR block does not overlap with an already existing VPC.

```
cat <<EOF > terraform.tfvars
# Global Vars
aws_cluster_name = "flooper"

# VPC Vars
aws_vpc_cidr_block       = "10.150.192.0/18"
aws_cidr_subnets_private = ["10.150.192.0/20", "10.150.208.0/20"]
aws_cidr_subnets_public  = ["10.150.224.0/20", "10.150.240.0/20"]

# Bastion Host
aws_bastion_size = "t3.medium"

# Kubernetes Cluster
aws_kube_master_num  = 1
aws_kube_master_size = "t3.medium"

aws_etcd_num  = 1
aws_etcd_size = "t3.medium"

aws_kube_worker_num  = 1
aws_kube_worker_size = "t3.medium"

# Settings AWS ELB
aws_elb_api_port                = 6443
k8s_secure_api_port             = 6443
kube_insecure_apiserver_address = "0.0.0.0"

default_tags = {
  #  Env = "devtest"
  #  Product = "kubernetes"
}

inventory_file = "../../../inventory/hosts"
EOF
```

* In `contrib/terraform/aws/credentials.tfvars`, set your AWS credentials. Don’t create a cluster unless you have access to a PEM file related to the AWS_SSH_KEY_NAME EC2 key pair.

```
AWS_ACCESS_KEY_ID = "111AXLYWH3DH2FGKSOFQ"
AWS_SECRET_ACCESS_KEY = "111dvxqDOX4RXJN7BQRZI/HD02WDW2SwV5Ck8R7F"
AWS_SSH_KEY_NAME = "keypair_name"
AWS_DEFAULT_REGION = "us-east-1"
```

## Create AWS Infrastructure

This should take about two minutes. If you have run `terraform apply` before, the generated files will not be overwritten. Therefore, they need to be deleted. That is why the `rm` command is here.

```
cd contrib/terraform/aws
#
# Sanity Check. See the files you will be deleting.
#
find ../../../inventory/artifacts ../../../inventory/hosts ../../../ssh-bastion.conf -type f

rm -rf ../../../inventory/artifacts ../../../inventory/hosts ../../../ssh-bastion.conf

#
# Sanity Check. Make sure the files are gone.
#
find ../../../inventory/artifacts ../../../inventory/hosts ../../../ssh-bastion.conf -type f

terraform init
terraform apply --var-file=credentials.tfvars --auto-approve
```

## Install Kubernetes

Run this from the project's root directory.

```
cd ../../..

time ansible-playbook \
  -i ./inventory/hosts \
  ./cluster.yml \
  -e ansible_user=centos \
  -e cloud_provider=aws \
  -e bootstrap_os=centos \
  --become \
  --become-user=root \
  --flush-cache \
  -e ansible_ssh_private_key_file=$PKI_PRIVATE_PEM \
  | tee kubespray-cluster-$(date "+%Y-%m-%d_%H:%M").log
```

## Setup kubectl

By default, the admin.conf file uses the private address of the controller node instead of the load balancer's hostname. The command below fixes this.

Run these commands from the project's root directory.

```
CONTROLLER_HOST_NAME=$(cat ./inventory/hosts | grep "\[kube-master\]" -A 1 | tail -n 1)
CONTROLLER_IP=$(cat ./inventory/hosts | grep $CONTROLLER_HOST_NAME | grep ansible_host | cut -d'=' -f2)
LB_HOST=$(cat inventory/hosts | grep apiserver_loadbalancer_domain_name | cut -d'"' -f2)

cd inventory/artifacts
cp admin.conf admin.conf.original
sed -i "s^server:.*^server: https://$LB_HOST:6443^" admin.conf
./kubectl --kubeconfig=admin.conf get nodes

cd ../..
```

Add `/data/projects/ic1/kubespray/inventory/artifacts` to the beginning of your `PATH` if you want to use that executable.

Copy `admin.conf` to `$HOME/.kube/config` if you want to use the new kubeconf from its default location. Take care not to overwrite any exsting file! However, I use the following command to create a symbolic link so that tools like `octant` will work.

```bash
rm $HOME/.kube/config
ln -s /data/projects/ic1/kubespray/inventory/artifacts/admin.conf $HOME/.kube/config
```

## SSH To Servers

Add `contrib/terraform/aws` to your path. Then use these scripts.

* ssh-to-bastion.sh
* ssh-to-controller.sh
* ssh-to-worker.sh
* ssh-to-etcd.sh

## Run kubebench

See https://medined.github.io/kubernetes/kubebench/kubespray/run-kubebench-on-kubespray-cluster/ if you want to run KubeBench on your cluster.

My results of the KubeBench are:

```
 59 PASS
 39 WARN
 24 FAIL
 20 INFO
---------
142 total
```

### Preparation

Now SSH into a bastion server.

Run the export commands displayed previously.

### Run Tests.

* The MASTER tests.

```
ssh -i $PKI_PRIVATE_PEM centos@$CONTROLLER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    --volume /var/lib/kubelet:/var/lib/kubelet:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets master \
    | tee kubebench-master-findings.log
```

* The ETCD tests.

```
ssh -i $PKI_PRIVATE_PEM centos@$ETCD_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets etcd \
    | tee kubebench-etcd-findings.log
```

* The CONTROL PLANE tests.

```
ssh -i $PKI_PRIVATE_PEM centos@$CONTROLLER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets controlplane \
    | tee kubebench-controlplane-findings.log
```

* The WORKER tests.

```
ssh -i $PKI_PRIVATE_PEM centos@$WORKER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /var/lib/kubelet:/var/lib/kubelet:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets node \
    | tee kubebench-node-findings.log
```

* The POLICY tests.

```
ssh -i $PKI_PRIVATE_PEM centos@$CONTROLLER_IP \
  sudo docker run \
    --pid=host \
    --rm=true \
    --volume /etc/kubernetes:/etc/kubernetes:ro \
    --volume /usr/bin:/usr/local/mount-from-host/bin:ro \
    aquasec/kube-bench:latest \
    --benchmark cis-1.5 run --targets policies \
    | tee kubebench-policies-findings.log
```

* Now exit from the bastion SSH session and copy the findings to your local computer.

```
scp -i $PKI_PRIVATE_PEM centos@3.238.68.82:kubebench-*.log .
```

## Setup Ingress Controller

In order to create an Network Load Balancer, run the following command.

```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/aws/deploy.yaml
```

Find the load balancer created by the `apply` command.

```
kubectl -n ingress-nginx get service ingress-nginx-controller --output=jsonpath="{.status.loadBalancer.ingress[0].hostname}"; echo
```

## Deploy An HTTP Application

* Create a subdomain for the application to be deployed. For example, `text-responder.davidm.xyz`. Point the subdomain to the network load balancer of the ingress-nginx service.

* Set an environment variable with the subdomain name.

```
export TEXT_RESPONDER_HOST="text-responder.davidm.xyz"
```


* Create a namespace.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
    name: text-responder
    labels:
        name: text-responder
EOF
```

* Deploy a small web server that returns a text message.

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: text-responder
  namespace: text-responder
spec:
  selector:
    matchLabels:
      app: text-responder
  replicas: 1
  template:
    metadata:
      labels:
        app: text-responder
    spec:
      containers:
      - name: text-responder
        image: hashicorp/http-echo
        args:
        - "-text=silverargint"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: text-responder
  namespace: text-responder
spec:
  ports:
  - port: 80
    targetPort: 5678
  selector:
    app: text-responder
EOF
```

* Forward a local port to the text-responder service to verify the service is working. While the following command is running, visit `http://localhost:7000` in your browser. Then using ^C to stop the port forwarding. An HTTPS request will fail.

```
kubectl -n text-responder port-forward service/text-responder 7000:80
```

* Create an Ingress for the service.

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: text-responder-ingress
  namespace: text-responder
spec:
  rules:
  - host: $TEXT_RESPONDER_HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: text-responder
            port:
              number: 80
EOF
```

* Call the service. It should return `silverargint`.

```bash
curl http://$TEXT_RESPONDER_HOST
```

* Create Let's Encrypt ClusterIssuer for staging and production environments. The main difference is the ACME server URL. I use the term `staging` because that is what Let's Encrypt uses.

>Change the email address.

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1beta1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: david.medinets@gmail.com
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
    email: david.medinets@gmail.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production-secret
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

* Check on the status of the development issuer. The entries should be ready.

```bash
kubectl get clusterissuer
```

* Update Ingress to use HTTPS.

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: text-responder-ingress
  namespace: text-responder
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  tls:
  - hosts:
    - $TEXT_RESPONDER_HOST
    secretName: text-responder-tls
  rules:
  - host: $TEXT_RESPONDER_HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: text-responder
            port:
              number: 80
EOF
```

* View the certificate. You’re looking for The certificate has been successfully issued in the message section. It may take a minute or two. If the certificate hasn’t been issue after five minutes, go looking for problems. Start in the logs of the pods in the nginx-ingress namespace.

```
kubectl --namespace text-responder describe certificate text-responder-tls
```

* View the secret:

```
kubectl -n text-responder get secret text-responder-tls
```

* Call the service. It should return `silverargint`.

```bash
curl -k https://$TEXT_RESPONDER_HOST
```

## Install KeyCloak

**Note that this KeyCloak as no backup and uses ephemeral drives. Any users and groups will be lost if the pods is restarted. I think.**

**Once you have KeyCloak integrated into the cluster, you (as the admin) will need to use `--context='admin'` and ``--context='medined'` to select which user to authenticate as.**

* Create a namespace.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
    name: keycloak
    labels:
        name: keycloak
EOF
```

* Create a password for the `admin` user. If you follow the process below, your KeyCloak will be on the internet so, at least, the password should be secure. You might be able to use port-forwarding but I haven't done that yet. **Don't loose the password!**. I'll also point out that the password is available to anyone who can read the YAML of the deployment. So, this technique might not be secure enough for your needs.

```bash
export KEYCLOAK_ADMIN_PASSWORD=$(uuid | cut -b-8)
echo $KEYCLOAK_ADMIN_PASSWORD
```

* I created `keycloak-admin-password.txt` and `keycloak-medined-password.txt` in my home directory to store the passwords used in this section. Then I used these commands. *Make sure you export these variables.*

```
export KEYCLOAK_ADMIN_PASSWORD=$(cat $HOME/keycloak-admin-password.txt)
export KEYCLOAK_MEDINED_PASSWORD=$(cat $HOME/keycloak-medined-password.txt)
```

* Create a service and deployment for KeyCloak. Check https://quay.io/repository/keycloak/keycloak?tab=tags to find out the latest image version.

See https://stackoverflow.com/questions/61819264/how-to-deploy-keycloak-on-kubernetes-with-custom-configuration for ideas about specifying a REALM in the `env` section and using a volume mount.

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:11.0.2
        env:
        - name: KEYCLOAK_USER
          value: "admin"
        - name: KEYCLOAK_PASSWORD
          value: $KEYCLOAK_ADMIN_PASSWORD
        - name: PROXY_ADDRESS_FORWARDING
          value: "true"
        ports:
        - name: http
          containerPort: 8080
        - name: https
          containerPort: 8443
        readinessProbe:
          httpGet:
            path: /auth/realms/master
            port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: keycloak
EOF
```

* Check the service is running. You should see the `keycloak` service in the list. The external IP should be `<none>`.

```bash
kubectl --namespace keycloak get service
```

* Find your Ingress Nginx Controller load balancer domain. The answer will look something like `aaXXXXf67c55949d8b622XXXX862dce0-bce30cd38eXXXX95.elb.us-east-1.amazonaws.com`.

```bash
kubectl -n ingress-nginx get service ingress-nginx-controller
```

* Create a vanity domain for KeyCloak. This domain needs to point to the load balancer found in the previous step. I use Route 53 but you can use any DNS service. Please make sure that your can correctly resolve the domain using `dig`.

```bash
export KEYCLOAK_HOST="keycloak.davidm.xyz"
```

* Curl should get the default 404 response. The HTTPS request should fail because the local issuer certificate can't be found.

```bash
curl http://$KEYCLOAK_HOST
```

```bash
curl https://$KEYCLOAK_HOST
```

* Create an ingress for the vanity domain. Note I am using the production cluster issuer because I have confidence it will work. If you are not confident, use the staging cluster issuer.

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak-ingress
  namespace: keycloak
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  tls:
  - hosts:
    - $KEYCLOAK_HOST
    secretName: keycloak-tls
  rules:
  - host: $KEYCLOAK_HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: keycloak
            port:
              number: 8080
EOF
```

* Review the certificate that cert-manager has created. You're looking for `The certificate has been successfully issued` in the message section. It may take a minute or two. If the certificate hasn't been issue after five minutes, go looking for problems. Start in the logs of the pods in the `nginx-ingress` namespace.

```bash
kubectl --namespace keycloak describe certificate keycloak-tls
```

* Review the secret that is being created by cert-manager.

```bash
kubectl --namespace keycloak describe secret keycloak-tls
```

* Display important URLs for KeyCloak

```bash
cat <<EOF
echo "Keycloak:                 https://$KEYCLOAK_HOST/auth"
echo "Keycloak Admin Console:   https://$KEYCLOAK_HOST/auth/admin"
echo "Keycloak Account Console: https://$KEYCLOAK_HOST/auth/realms/myrealm/account"
EOF
```

* Visit KeyCloak.

```bash
xdg-open https://$KEYCLOAK_HOST/auth
```

* Follow the procedures at https://www.keycloak.org/getting-started/getting-started-kube starting at "Login to the admin console".

* Don't create a new realm. Just use `master` unless you are experienced with Keycloak.

* **NOTE** - When creating a client, make sure to set the Access Type to `confidential`. This will ensure that client secrets are available. You'll need to use `/` (just the slash) as the Valid Redirect URIs value. Click on the Credentials tab which only shown **after** you switch to `confidential` as click Save. Make note of the Secret. I store my secret at `$HOME/keycloak-client-secret.txt`. It is needed when users authenticate.

* Create a client named `kubernetes-cluster`.

* Create a user. Mine is `medined`. Then assign a password to the user and disable `Temporary` before clicking 'Set Password'.

* Create RBAC for the new user. Change "medined" below to your new username. The role rules are purely here to provide a simple example. Update them to match your own requirements. Especially, the KeyCloak hostname.

**Using `kubectl` without a context parameter works because `~/.kube/config` has not yet been updated.**

```bash
USERNAME=medined

kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $USERNAME
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: $USERNAME-role
  namespace: $USERNAME
rules:
  - apiGroups: ['']
    resources: [pods]
    verbs:     [get, list, watch, create, update, patch, delete]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: $USERNAME-role-binding
  namespace: $USERNAME
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $USERNAME-role
subjects:
- kind: User
  name: https://$KEYCLOAK_HOST/auth/realms/master#$USERNAME
  namespace: $USERNAME
EOF
```

* Create a credential-setup script which add a user configration to `~/.kube/config`. Adapt this script to your needs. Especially, the `IDP_ISSUER_URL`. This script is just an example.

**Add this script to cron in order to never worry about stale tokens! I use `*/30 * * * * /home/medined/medined-credentials-setup.sh`. If you want to get fancy, you can use $LOGNAME instead of hardcoding the user name.**

```bash
USERNAME=medined

cat <<EOF > $HOME/$USERNAME-credentials-setup.sh
#!/bin/bash

CLUSTER="$CLUSTER"
USERNAME="$USERNAME"
PASSWORD="$(cat $HOME/keycloak-medined-password.txt)"
NAMESPACE="$USERNAME"
IDP_ISSUER_URL="https://$KEYCLOAK_HOST/auth/realms/master"
IDP_CLIENT_ID="kubernetes-cluster"
IDP_CLIENT_SECRET="$(cat $HOME/keycloak-client-secret.txt)"

IDP_TOKEN=\$(curl -X POST \
  \$IDP_ISSUER_URL/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=\$IDP_CLIENT_ID \
  -d client_secret=\$IDP_CLIENT_SECRET \
  -d username=\$USERNAME \
  -d password=\$PASSWORD \
  -d scope=openid \
  -d response_type=id_token \
  | jq -r '.id_token')

REFRESH_TOKEN=\$(curl -X POST \
 \$IDP_ISSUER_URL/protocol/openid-connect/token \
 -d grant_type=password \
 -d client_id=\$IDP_CLIENT_ID \
 -d client_secret=\$IDP_CLIENT_SECRET \
 -d username=\$USERNAME \
 -d password=\$PASSWORD \
 -d scope=openid \
 -d response_type=id_token \
 | jq -r '.refresh_token')

kubectl config set-credentials medined \
  --auth-provider=oidc \
  --auth-provider-arg=client-id=\$IDP_CLIENT_ID \
  --auth-provider-arg=client-secret=\$IDP_CLIENT_SECRET \
  --auth-provider-arg=idp-issuer-url=\$IDP_ISSUER_URL \
  --auth-provider-arg=id-token=\$IDP_TOKEN \
  --auth-provider-arg=refresh-token=\$REFRESH_TOKEN

kubectl config set-context medined \
  --cluster=\$CLUSTER \
  --user=\$USERNAME \
  --namespace=\$NAMESPACE
EOF

chmod +x $HOME/$USERNAME-credentials-setup.sh
```

* Execute the new script.

```bash
$HOME/$USERNAME-credentials-setup.sh
```

* Now you can use the context in your `kubectl` command like this:

```bash
kubectl --context=$USERNAME --namespace $USERNAME get pods
```

## Install Istio

* Download Istio.

```bash
curl -L https://istio.io/downloadIstio | sh -
```

* Put the download directory in your PATH.

```bash
export PATH="$PATH:/data/projects/ic1/kubespray/istio-1.7.1/bin"
```

* Connect to the installation directory.

```bash
cd istio-1.7.1
```

* Run the precheck.

```bash
istioctl x precheck
```

* Install Istio with the demo configuration profile.

```bash
istioctl install --set profile=demo
```

* Create a namespace for testing Istio.

```bash
kubectl create namespace playground
```

* Enable Istio in the playground namespace.

```bash
kubectl label namespace playground istio-injection=enabled
```

* Deploy the sample application.

```bash
kubectl --namespace playground apply -f samples/bookinfo/platform/kube/bookinfo.yaml
```

* Check the pods and services. Keep checking the pods until they are ready.

```bash
kubectl --namespace playground get services
kubectl --namespace playground get pods
```

* Verify the application is running and serving HTML pages. If the application is working correctly, the response will be `<title>Simple Bookstore App</title>`.

```bash
kubectl --namespace playground exec "$(kubectl --namespace playground get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')" -c ratings -- curl -s productpage:9080/productpage | grep -o "<title>.*</title>"
```

* Open the application to outside traffic by associating the application to the istio gateway.

```bash
kubectl --namespace playground apply -f samples/bookinfo/networking/bookinfo-gateway.yaml
```

* Check the configuration for errors.

```bash
istioctl --namespace playground analyze
```

* Get connection information.

```
export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
```

* Set the gateway URL.

```bash
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
```

* Visit the product page in your browser.

```bash
xdg-open http://$GATEWAY_URL/productpage
```

* Install the Kiali dashboard, along with Prometheus, Grafana, and Jaeger.

```bash
kubectl apply -f samples/addons
while ! kubectl wait --for=condition=available --timeout=600s deployment/kiali -n istio-system; do sleep 1; done
```

* Visit the Kiali dashboard.

```bash
istioctl dashboard kiali
```

## Destroy Cluster

```
cd contrib/terraform/aws
terraform destroy --var-file=credentials.tfvars --auto-approve
```
