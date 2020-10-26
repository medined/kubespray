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

I was not able to use the pre-configured proxy to SSH into the nodes. Instead I did the following:

Run the following commands to learn the IP address of each server.

```
CONTROLLER_HOST_NAME=$(cat ./inventory/hosts | grep "\[kube-master\]" -A 1 | tail -n 1)
CONTROLLER_IP=$(cat ./inventory/hosts | grep $CONTROLLER_HOST_NAME | grep ansible_host | cut -d'=' -f2)

WORKER_HOST_NAME=$(cat ./inventory/hosts | grep "\[kube-node\]" -A 1 | tail -n 1)
WORKER_IP=$(cat ./inventory/hosts | grep $WORKER_HOST_NAME | grep ansible_host | cut -d'=' -f2)

ETCD_HOST_NAME=$(cat ./inventory/hosts | grep "\[etcd\]" -A 1 | tail -n 1)
ETCD_IP=$(cat ./inventory/hosts | grep $ETCD_HOST_NAME | grep ansible_host | cut -d'=' -f2)

# Use these export commands on the bastion server.
cat <<EOF
export CONTROLLER_IP=$CONTROLLER_IP
export WORKER_IP=$WORKER_IP
export ETCD_IP=$ETCD_IP
export PKI_PRIVATE_PEM=$(basename $PKI_PRIVATE_PEM)
EOF
```

Run those export commands each time you SSH into a bastion server.

```
export BASTION_IP=$(grep ^bastion inventory/hosts | head -n 1 | cut -d'=' -f2)

# Copy the PEM file to the bastion node.
scp -i $PKI_PRIVATE_PEM $PKI_PRIVATE_PEM centos@$BASTION_IP:.

# Now I can SSH to the bastion node.
ssh -i $PKI_PRIVATE_PEM centos@$BASTION_IP

#
# Execute export commands
#

# Now I can SSH to the cluster nodes.
ssh -i $PKI_PRIVATE_PEM centos@$CONTROLLER_IP
ssh -i $PKI_PRIVATE_PEM centos@$WORKER_IP
ssh -i $PKI_PRIVATE_PEM centos@$ETCD_IP
```

## Run kubebench

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


## Destroy Cluster

```
cd contrib/terraform/aws
terraform destroy --var-file=credentials.tfvars --auto-approve
```
