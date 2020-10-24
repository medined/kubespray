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

* In `contrib/terraform/aws/terraform.tfvars`, set variables as needed. Note that the inventory file will be created a few levels up in the directory tree.

```
cat <<EOF > terraform.tfvars
# Global Vars
aws_cluster_name = "flooper"

# VPC Vars
aws_vpc_cidr_block       = "10.250.192.0/18"
aws_cidr_subnets_private = ["10.250.192.0/20", "10.250.208.0/20"]
aws_cidr_subnets_public  = ["10.250.224.0/20", "10.250.240.0/20"]

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

This should take about two minutes.

```
cd contrib/terraform/aws
terraform init
terraform apply --var-file=credentials.tfvars --auto-approve
```

## Install Kubernetes

Run this from the project's root directory.

```
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
  | tee /tmp/kubespray-cluster-$(date "+%Y-%m-%d_%H:%M").log
```

## Setup kubectl

By default, the admin.conf file uses the private address of the controller node instead of the load balancer's hostname. The command below fix this.

```
CONTROLLER_HOST_NAME=$(cat ./inventory/hosts | grep "\[kube-master\]" -A 1 | tail -n 1)
CONTROLLER_IP=$(cat ./inventory/hosts | grep $CONTROLLER_HOST_NAME | grep ansible_host | cut -d'=' -f2)
LB_HOST=$(cat inventory/hosts | grep apiserver_loadbalancer_domain_name | cut -d'"' -f2)

cd inventory/artifacts
cp admin.conf admin.conf.original
sed -i "s^server:.*^server: https://$LB_HOST:6443^" admin.conf
./kubectl --kubeconfig=admin.conf get nodes
```

Add `/data/projects/ic1/kubespray/inventory/artifacts` to the beginning of your `PATH` if you want to use that executable.

Copy `admin.conf` to `$HOME/.kube/config` if you want to use the new kubeconf from its default location. Take care not to overwrite any exsting file! However, I use the following command to create a symbolic link so that tools like `octant` will work.

```bash
ln -s /data/projects/ic1/kubespray/inventory/artifacts/admin.conf $HOME/.kube/config
```

## SSH To Servers

I was not able to use the pre-configured proxy to SSH into the nodes. Instead I did the following:


```
# Copy the PEM file to the bastion node.
scp -i $PKI_PRIVATE_PEM $PKI_PRIVATE_PEM centos@3.238.68.82:.

# Now I can SSH to the bastion node.
ssh -i $PKI_PRIVATE_PEM centos@3.238.68.82

# Now I can SSH to the cluster nodes.
ssh -i davidm.xyz.pem centos@10.250.207.223
ssh -i davidm.xyz.pem centos@10.250.192.72
ssh -i davidm.xyz.pem centos@10.250.198.215
```

## Run kubebench

### Preparation

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

## Destroy Cluster

```
cd contrib/terraform/aws
terraform destroy --var-file=credentials.tfvars --auto-approve
```
