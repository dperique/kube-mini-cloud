# Creating Micro Kubernetes Clusters using Kubespray

A "Micro Kubernetes Cluster" is just another Kubernetes cluster running inside
the Kube Stack Kubernetes cluster -- i.e., kube in kube.

Creating a Kubernetes cluster inside (i.e., hosted on) a Kube Stack is identical
to creating it on baremetal servers or VMs outside of Kube Stack -- except for
how you obtain the baremetal servers or VMs of course.

The only difference is that you first create your VMs using kubevirt:

* one VM to run kubespray (I run kubespray in a Pod but it doesn't matter)
* N VMs to make up the Kubernetes cluster (I use 5 VMs)
* Setup the inventory by referring to the
  [micro-kube-inventory](https://github.com/dperique/kube-mini-cloud/tree/master/kube-stack/micro-kube-inventory)
  subdir in this repo
  * I use a script (make_inventory.sh) to generate the inventory file.  This
    is optional but is encouraged because we want to make these micro kube clusters
    as fast as possible using automation.
* Pay particular attention to the group_vars/all subdirectory and note two things:
  * The micro kube cluster Pod address space is different than the Kube Stack address
    space.  This is to avoid address conflicts.
  * The micro kube cluster has a smaller MTU than the default.  In my case, I use calico
    with ip-in-ip.  If you do this, you end up ip-in-ip-in-ip-in-ip which means
    there are two levels of ip-in-ip encapsulation.  If you keep the orignal MTU, you will
    get a lot of IP fragmentation and hence horrible (and usually not working)
    performance problems.

In summary:

* Install [kubespray](https://github.com/kubernetes-incubator/kubespray) on a Pod
  or VM, setup your defaults (in my case, I'm using kubespray v2.7.0, calico for networking,
  ip-in-ip)
* Create your inventory and group_vars/all files
* Run kubespray

From the VM or Pod running kubespray, you should be able to run kubectl on your
micro kube cluster.  Or ssh into one of your Kubernetes masters and run kubectl there.

## Example: create a Kubernetes cluster for CI testing

Our goal is to make a Kubernetes cluster inside Kubernetes so that we can run
tests on it and then destroy it.  I call this cluster "ci-kube".

My hosting Kubernetes cluster is called "kube-test".  On kube-test, I have one
big BM (baremetal) machine where I will run the ci-kube k8s nodes (VMs using
kubevirt) plus a container to run kubespray to create the Kubernetes cluster.

## Create the VMs using kubevirt

```
aFile="ubuntu-16.04-minimal.yaml"
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-$i/"| kubectl apply -f - ; done

virtualmachineinstance.kubevirt.io/ci-kube-1 created
virtualmachineinstance.kubevirt.io/ci-kube-2 created
virtualmachineinstance.kubevirt.io/ci-kube-3 created
virtualmachineinstance.kubevirt.io/ci-kube-4 created
virtualmachineinstance.kubevirt.io/ci-kube-5 created
```

Wait for the VMs to be up:

```
$ kubectl -n kubevirt get vmis
NAME        AGE       PHASE     IP             NODENAME
ci-kube-1   17h       Running   10.233.67.80   kube-test-10
ci-kube-2   17h       Running   10.233.67.76   kube-test-10
ci-kube-3   17h       Running   10.233.67.82   kube-test-10
ci-kube-4   17h       Running   10.233.67.81   kube-test-10
ci-kube-5   17h       Running   10.233.67.79   kube-test-10
```

## Setup a container to run kubespray

Create a container using `files/makeCont.sh` and install kubespray, create an inventory,
and include these variables to be used in kubespray:

```
kube_service_addresses: 10.239.0.0/18
kube_pods_subnet: 10.239.64.0/18
dnsmasq_dns_server: 10.239.0.2
skydns_server: 10.239.0.3
calico_mtu: 1400
```

Those values are different from the 10.233.0.0 default values in kubespray because
I used kubespray to create my kube-test k8s cluster, and if I did not change them, the
defaults would overlap with the Kubernetes node IP addresses (which are VMs inside my
Kubernetes cluster) making the Kubernetes networking for the ci-kube cluster quite
unpredictable.  So we use non-overlapping values.

I found the uses of 10.233.0.0 using this search:

```
find . -name '*' | xargs grep 10.233 2> /dev/null |grep -v weav|grep -v flannel|grep -v vars.md| grep -v contiv|grep -v openstack
```

The inventory (I should have used ubuntu, but oh well, TODO: generate this inventory from
the list of VMs that just got created):

```
$ cat hosts 
ci-kube-k8s-node-1 ansible_host=10.233.67.80 ip=10.233.67.80 ansible_user=root
ci-kube-k8s-node-2 ansible_host=10.233.67.76 ip=10.233.67.76 ansible_user=root
ci-kube-k8s-node-3 ansible_host=10.233.67.82 ip=10.233.67.82 ansible_user=root
ci-kube-k8s-node-4 ansible_host=10.233.67.81 ip=10.233.67.81 ansible_user=root
ci-kube-k8s-node-5 ansible_host=10.233.67.79 ip=10.233.67.79 ansible_user=root

[kube-master]
ci-kube-k8s-node-1
ci-kube-k8s-node-2
ci-kube-k8s-node-3

[etcd]
ci-kube-k8s-node-1
ci-kube-k8s-node-2
ci-kube-k8s-node-3
ci-kube-k8s-node-4
ci-kube-k8s-node-5

[kube-node]
ci-kube-k8s-node-1
ci-kube-k8s-node-2
ci-kube-k8s-node-3
ci-kube-k8s-node-4
ci-kube-k8s-node-5

[k8s-cluster:children]
kube-node
kube-master
```

## Prepare the VMs for kubespray installation

For each VM, I allowed ssh access via root so I can make any modifications necessary to
run kubespray.  For each VM, do this (in the ubuntu_16.04-minimal.yaml I added this to
the cloudinit so you don't have to do it manually if you use that yaml to create your
VMs):

```
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
apt-add-repository ppa:ansible/ansible ; apt-get update ; apt-get install -y ansible ; apt-get install -y python
cat << END > /etc/docker/daemon.json
{
  "bip": "192.168.0.1/16"
}
END
```

The first line puts the ubuntu user in the sudoers list so that we can use ubuntu in the
kubespray inventory file.  The second one installs python (a requirement to run kubespray).
The last set of lines changes the default docker subnet.  Ensure that
this subnet does not overlap with a network you will access from the new Kubernetes cluster.

## Run kubespray and view the Kubernetes cluster

Run kubespray (we are using kubespray v2.4.0) from your container you built earlier.  Your
Kubernetes cluster should be created.

Here is some kubectl output to show the newly created ci-kube Kubernetes cluster:

```
$ kubectl get node
NAME                 STATUS    ROLES         AGE       VERSION
ci-kube-k8s-node-1   Ready     master,node   16h       v1.10.11
ci-kube-k8s-node-2   Ready     master,node   16h       v1.10.11
ci-kube-k8s-node-3   Ready     master,node   16h       v1.10.11
ci-kube-k8s-node-4   Ready     node          16h       v1.10.11
ci-kube-k8s-node-5   Ready     node          16h       v1.10.11
```

I created it with 3 masters and 2 workers for HA mode.

Here are the pods in the kube-system namespace:

```
$ kubectl get po -n kube-system -o wide
NAME                                         READY     STATUS    RESTARTS   AGE       IP             NODE
calico-node-4b5wt                            1/1       Running   0          16h       10.233.67.80   ci-kube-k8s-node-1
calico-node-5pd2v                            1/1       Running   0          16h       10.233.67.81   ci-kube-k8s-node-4
calico-node-pfb9j                            1/1       Running   0          16h       10.233.67.76   ci-kube-k8s-node-2
calico-node-tttmh                            1/1       Running   0          16h       10.233.67.79   ci-kube-k8s-node-5
calico-node-zbmp7                            1/1       Running   0          16h       10.233.67.82   ci-kube-k8s-node-3
kube-apiserver-ci-kube-k8s-node-1            1/1       Running   0          16h       10.233.67.80   ci-kube-k8s-node-1
kube-apiserver-ci-kube-k8s-node-2            1/1       Running   0          16h       10.233.67.76   ci-kube-k8s-node-2
kube-apiserver-ci-kube-k8s-node-3            1/1       Running   0          16h       10.233.67.82   ci-kube-k8s-node-3
kube-controller-manager-ci-kube-k8s-node-1   1/1       Running   0          15h       10.233.67.80   ci-kube-k8s-node-1
kube-controller-manager-ci-kube-k8s-node-2   1/1       Running   0          16h       10.233.67.76   ci-kube-k8s-node-2
kube-controller-manager-ci-kube-k8s-node-3   1/1       Running   0          16h       10.233.67.82   ci-kube-k8s-node-3
kube-dns-5466774c4f-qtf54                    3/3       Running   0          16h       10.239.111.2   ci-kube-k8s-node-4
kube-dns-5466774c4f-xkq47                    3/3       Running   0          16h       10.239.87.65   ci-kube-k8s-node-5
kube-proxy-ci-kube-k8s-node-1                1/1       Running   0          16h       10.233.67.80   ci-kube-k8s-node-1
kube-proxy-ci-kube-k8s-node-2                1/1       Running   0          16h       10.233.67.76   ci-kube-k8s-node-2
kube-proxy-ci-kube-k8s-node-3                1/1       Running   0          16h       10.233.67.82   ci-kube-k8s-node-3
kube-proxy-ci-kube-k8s-node-4                1/1       Running   0          16h       10.233.67.81   ci-kube-k8s-node-4
kube-proxy-ci-kube-k8s-node-5                1/1       Running   0          16h       10.233.67.79   ci-kube-k8s-node-5
kube-scheduler-ci-kube-k8s-node-1            1/1       Running   0          15h       10.233.67.80   ci-kube-k8s-node-1
kube-scheduler-ci-kube-k8s-node-2            1/1       Running   0          16h       10.233.67.76   ci-kube-k8s-node-2
kube-scheduler-ci-kube-k8s-node-3            1/1       Running   0          16h       10.233.67.82   ci-kube-k8s-node-3
kubedns-autoscaler-679b8b455-78fvf           1/1       Running   0          16h       10.239.111.1   ci-kube-k8s-node-4
nginx-proxy-ci-kube-k8s-node-4               1/1       Running   0          16h       10.233.67.81   ci-kube-k8s-node-4
nginx-proxy-ci-kube-k8s-node-5               1/1       Running   0          16h       10.233.67.79   ci-kube-k8s-node-5
```

Note the IP addresses of the pods.  The ones with 10.239.0.0 as configured above are pods created
using the network plugin (calico).  The ones using 10.233.0.0 (the subnet for the ci-kube k8s nodes)
are "static" pods; those pods have the same IP as the node where they reside on.
