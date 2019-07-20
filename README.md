# The Kube mini Cloud

## Introduction

In creating the Kuul Periodic System, I found that it would be nice to be able to debug
certain containers used to run periodic scripts in a way that is interactive (e.g., being
about to interactively start and abort the script via control-c, and tweak files on the
fly is nice for debugging, etc.).  So I started
to create a new Dockerfile and image just like the usual Kuul Image but with ssh enabled.
I ran the container in docker and used it that way.  This was cumbersome (I still had to
coordinate ports to map to ssh, orchestrate many containers for different debugging
sessions, etc. so I then went and built Kubernetes pods out of the new docker image.

I then started to contemplate that this is much like creating VMs in a cloud (much like
we do in Openstack).  So then, I started to think::

* I'd like a cloud (like Openstack) that can create Pods for me so that I can do
  interactive debugging (much like logging into a VM but using Pods)
* I'd also like this cloud to be able to spin up VMs for things that cannot run in a Pod
  * Examples:
    * Testing out one of our periodic deployment scripts requires a Kubernetes cluster
      that I can create using minikube or microk8s
    * Testing out one of our k8s deployment scripts requires having some fresh VMs
      so we can create a k8s cluster

## My mini solution: create a cloud that supports both

I solution is "mini" in that I am going to solve my immediate needs but keep the solution
limited to immediate needs; this way, I won't spend too much time on it as I also need
time to use it.

I chose the platform at Kubernetes because it can already run Pods.  I also found kubevirt
which allows you to create VMs in Kubernetes.  So, I will get the best of both worlds.
Following the "mini" philosophy, I will set this up and make it someone easy to create Pods
and VMs so I can do my testing but won't spend time to create a GUI, etc. or any of the
other fancy things that Openstack provides.

I already had a k8s cluster but added a big 64CPU/96G machine as a worker node to run Pods
and VMs.

## Pods running ssh

The Docker container used by the Pods will be the same Docker container used to run periodic
jobs in Kuul but, we will add ssh to them.  Like in Kuul, we can use nodeSelectors to steer
those Pods to specific k8s nodes.  When a Pod spins up, I will ssh to
it and run my script interactively.  When I'm done with the Pod or just want a new one without
my debugging changes, I will destroy it (via `kubectl delete pod`) and create a new one.

The Pods:

* Will have a service attached to them.  This Service can be kept around so that the
  IP never changes. Optionally, you can put those IPs in a DNS server and reference the Pods
  using that
* Later, you can use a Kubernetes Deployment vs. just a Podspec so that you can
  delete the Pod when you're done with it and it will be restarted fresh automatically.
* You can login to the Pods via one of the nodes in the Kubernetes cluster (you can
  do this because every node in the k8s cluster should be able to reach every Pod).  If this
  is not true, you can either use a NodePort (expose the ssh port of your Pods via unique
  ports outside of the k8s cluster) or login to the Pod though the node where the Pod
  physically resides.

## Connecting to the Pods

I use an ssh config file like this to allow me to ssh to a Pod by user defined name (e.g.,
dp-test1 and dp-test2) through a particluar k8s node (i.e., kube-test-10):

```
Host kube-test-10
  HostName 192.168.203.108
  User ubuntu
  IdentityFile ~/.ssh/kube-test.rsa

Host dp-test1
  User ubuntu
  HostName 10.233.7.6  <-- this is a Pod IP
  StrictHostKeyChecking no
  ProxyCommand ssh -A -W %h:%p kube-test-10
  IdentityFile ~/.ssh/junk.id_rsa

Host dp-test2
  User ubuntu
  HostName 10.233.60.196 <-- this is a Pod IP
  StrictHostKeyChecking no
  ProxyCommand ssh -A -W %h:%p kube-test-10
  IdentityFile ~/.ssh/junk.id_rsa
```

With that file in `~/.ssh/config` or if you alias "ssh" to use that config,
we can do this:

```
$ alias ssh="ssh -F ~/ssh_config"
$ ssh dp-test1
```

The above will ssh to 10.233.7.6 through k8s node kube-test-10.  You can also use the service
IP address instead of the Pod IP address.

In my k8s cluster, we use calico for networking.  One day, we will setup a BGP router using
bird and peer calico with that router so that we can reach the Pod IPs using normal routing.
In this case, we will have to be careful to create the k8s cluster using a subnet other than
the 10.233.x.x that is used in all of our other k8s clusters.

## Creating and Deleting the Pods

The entity that creates/deletes the Pods will dynamically create/update the ssh config file
so that it will always be up to date with the current state in k8s (i.e., the IPs will always
be correct).  This won't be a problem if you use Services which persist across Pod delete
and create.

If you want persistent storage, you can use hostPath volumes to store your data and mount
these to the Pods.  In this way, the files you may be using for debugging will persist
across Pod restarts.

I use a bash script (in source/makeCont.sh) that uses a Pod template and kubectl to create
and destroy the Pods.  This script also generates the ssh config after each create/destroy.

The Pod template (in source/64ssh.yaml) is setup so that we can use simple sed substitution
to generate unique Pods.  The Pods have these characteristics:

* The template mounts a secrets volume so that you can keep your Docker images free of
  secrets.  In the Pod, you can acces the secrets in `/var/secrets`.
  * Create the kuul-secret by modifying the source/kuul-secrets.yaml file and then doing
    `kubectl apply -f kuul-secrets.yaml --namespace kuul-test`
* We run the testing Pods in a namespace called `kuul-test` to keep them separate
* We use a nodeSelector so that we can steer the test Pods to particular k8s nodes
  * Label your node using `kubectl label node --overwrite kube-test-10 kuul-type=ssh`
* We use DNS from the host via `dnsPolicy: Default`.  You can change this if you want
  depending on what you're doing.

## Loading the Docker images

If you have a docker registry available (highly recommended), you can use that for storing
images.

If you don't have a docker registry, you can get your docker images onto the k8s nodes
directly via something like this (assume IP1, IP2, IP3 are IP addresses of my k8s nodes
where I intend to run the new Pods:

```
docker build -t kube-mc:0.1 .
docker save -o /tmp/o.tar kube-mc:0.1
tar czvf ./t.tgz ./o.tar
for i in IP1 IP2 IP3 ; do
  scp -i junk.rsa t.tgz ubuntu@$i:/tmp
  ssh -i junk.rsa ubuntu@$i  "cd /tmp ; tar xzvf /tmp/t.tgz"
  ssh -i junk.rsa ubuntu@$i  "cd /tmp ; sudo docker load -i o.tar"
done
```

The above script (see source/load_docker_images.sh) loads the images directly onto the docker
instance of those nodes.  This way, when you start up the Pod, it won't need to goto a container
registry because it will already be present.  You will have to set the imagePullPolicy to
IfNotPresent.

## Creating the Pods

Once the image is loaded into a container registry with registry secret installed on your
k8s cluster or you have loaded the docker image manually onto your k8s nodes, and you set
your kubectl context to your k8s clsuter, you can do this

```
$ for i in {01..03} ; do ./makeCont.sh create dp-test$i kube-mc:0.1 ; done

...

service/dp-test03 created
pod/dp-test03 created

      dp-test01   10.233.55.60
      dp-test02   10.233.46.137
      dp-test03   10.233.6.45

alias ssh="ssh -F ./ssh_config"  <-- Do this so you can use the ssh_config file

$ alias ssh="ssh -F ./ssh_config"

$ ssh dp-test01
...
ubuntu@dp-test01:~$ sudo su   <-- see that we have sudo privilege
root@dp-test01:/home/ubuntu# exit
exit
ubuntu@dp-test01:~$ exit
logout
Connection to 10.233.55.60 closed.
```

In the kuul-test namespace, you will see dp-test01, dp-test02, dptest03 Pods.  You can
then run the alias ssh command as printed and then login via "ssh dp-test01" for example.

Here's some kubectl output:

```
$ kubectl -n kuul-test get po -o wide | grep dp-test
dp-test01   1/1       Running   0          3m57s     10.233.67.68    kube-test-10
dp-test02   1/1       Running   0          3m55s     10.233.67.69    kube-test-10
dp-test03   1/1       Running   0          3m53s     10.233.67.70    kube-test-10

$ kubectl -n kuul-test get svc  | grep dp-test
dp-test01   ClusterIP   10.233.55.60    <none>        22/TCP    4m17s <-- the one shown above
dp-test02   ClusterIP   10.233.46.137   <none>        22/TCP    4m15s
dp-test03   ClusterIP   10.233.6.45     <none>        22/TCP    4m13s
```

## Creating the VMs

We will use [kubevirt](https://kubevirt.io/user-guide/docs/latest/welcome/index.html) which requires
some setup.  See the [kubevirt github repo](https://github.com/kubevirt/kubevirt) for more information.
I will copy and annotate the demo you will find elsewhere on the web (credit goes there).

This [kubevirt architecture](https://github.com/kubevirt/kubevirt/blob/master/docs/architecture.md)
document helps to understand what kubevirt is.

## Some setup for kubevirt

NOTES:
  * this [doc](https://github.com/kubevirt/user-guide/blob/master/administration/intro.adoc) has
    just about everything you need to get started.
  * install using [ansible playbooks](https://github.com/kubevirt/kubevirt-ansible)
    * including a [role that installs go](https://github.com/jlund/ansible-go)

On the hosts that will be running VMs using kubevirt
[Enable nested virtualization](https://docs.fedoraproject.org/en-US/quick-docs/using-nested-virtualization-in-kvm/index.html)
like this:

```
  sudo su
  modprobe -r kvm_intel
  modprobe kvm_intel nested=1
```

Apply the demo like this:

```
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v0.19.0/kubevirt-operator.yaml
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v0.19.0/kubevirt-cr.yaml
```

You will see something like this:

```
kubevirt-operator.yaml
namespace/kubevirt created
customresourcedefinition.apiextensions.k8s.io/kubevirts.kubevirt.io created
clusterrole.rbac.authorization.k8s.io/kubevirt.io:operator created
serviceaccount/kubevirt-operator created
clusterrole.rbac.authorization.k8s.io/kubevirt-operator created
clusterrolebinding.rbac.authorization.k8s.io/kubevirt-operator created
deployment.apps/virt-operator created

$ kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v0.19.0/kubevirt-cr.yaml
kubevirt.kubevirt.io/kubevirt created
```

In my caes, I have several nodes; the `virt-handler` daemonset will create a virt-hanlder
pod on every k8s node.  Later, I'll make it so that only my kube-test-10 k8s gets it but
this is what you'll see:

```
$ kubectl get po -n kubevirt
NAME                               READY     STATUS    RESTARTS   AGE
virt-api-cd767567-hqf25            1/1       Running   0          91s
virt-api-cd767567-rtvft            1/1       Running   0          91s
virt-controller-7d6fb4d9c5-2sxz9   1/1       Running   0          68s
virt-controller-7d6fb4d9c5-9kjqt   1/1       Running   0          67s
virt-handler-2p2w9                 1/1       Running   0          67s
virt-handler-fdvm2                 1/1       Running   0          67s
virt-handler-jrpcw                 1/1       Running   0          67s
virt-handler-qfrpp                 1/1       Running   0          67s
virt-handler-wvz96                 1/1       Running   0          67s
virt-handler-z4jdl                 1/1       Running   0          67s
virt-operator-7b5488c788-b5dlj     1/1       Running   0          2m30s
virt-operator-7b5488c788-w78wx     1/1       Running   0          2m30s
```

Get virtctl and move it to a place where you can run it:

```
$ curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/v0.19.0/virtctl-v0.19.0-linux-amd64
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   617    0   617    0     0    650      0 --:--:-- --:--:-- --:--:--   650
100 36.5M  100 36.5M    0     0  18.3M      0  0:00:01  0:00:01 --:--:-- 65.1M
$ chmod +x virtctl
$ sudo mv virtctl /usr/local/bin
```

## Run the basic kubevirt demo for CirrOS

This [demo](https://kubevirt.io//quickstart_minikube/) gives an idea of what to do but stops short of
creating a VM.

This [kubevirt lab1](https://kubevirt.io//labs/kubernetes/lab1) exercise creates a VM.

I put the commands here for easy access and downloaded the
[vm.yaml](`https://raw.githubusercontent.com/kubevirt/kubevirt.github.io/master/labs/manifests/vm.yaml`) file
and placed it in the `files` subdir so you can view it without downloading it.

```
$ wget https://raw.githubusercontent.com/kubevirt/kubevirt.github.io/master/labs/manifests/vm.yaml
$ kubectl apply -f vm.yaml
virtualmachine.kubevirt.io "testvm" created
  virtualmachineinstancepreset.kubevirt.io "small" created
$ kubectl get vms
$ kubectl get vms -o yaml testvm
$ virtctl start testvm
$ kubectl get vmis
$ kubectl get vmis -o yaml testvm
```

See that the VM is present but not running and then start the VM:

```
$ kubectl get vms
NAME      AGE       RUNNING   VOLUME
testvm    1d        false

$ kubectl describe vms testvm|grep -i running
...
  Running:  false

$ virtctl start testvm
VM testvm was scheduled to start
```

Give it a few minutes and the console will spew logs as the VM starts up.
Login and see what interfaces are present and the IP address:

```
$ virtctl console testvm
...
############ debug end   ##############
  ____               ____  ____
 / __/ __ ____ ____ / __ \/ __/
/ /__ / // __// __// /_/ /\ \
\___//_//_/  /_/   \____/___/
   http://cirros-cloud.net


login as 'cirros' user. default password: 'gocubsgo'. use 'sudo' for root.
testvm login: cirros
Password: gocubsgo

$ ip -4 addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue qlen 1
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast qlen 1000
    inet 10.233.67.73/32 brd 10.255.255.255 scope global eth0
       valid_lft forever preferred_lft forever
$
```

In my case, I want to force it to use a public DNS server and ping some random
website; I do this inside the VM:

```
$ sudo su
$ echo "nameserver 8.8.8.8" > /etc/resolv.conf
$ cat /etc/resolv.conf
nameserver 8.8.8.8
$ ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: seq=0 ttl=53 time=2.699 ms
^C
--- 8.8.8.8 ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 2.699/2.699/2.699 ms
$ ping www.intel.com
PING www.intel.com (184.24.100.5): 56 data bytes
64 bytes from 184.24.100.5: seq=0 ttl=53 time=1.669 ms
^C
--- www.intel.com ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 1.669/1.669/1.669 ms
```

You can see above that the VM has Internet access.

Exit out of the virtctl console by typing "control-]".

Stop the VM and confirm it is no longer running.

```
$ virtctl stop testvm
VM testvm was scheduled to stop

$ kubectl describe vms testvm|grep -i runn
...
  Running:  false
```

Delete the VM like this:

```
$ kubectl delete vm testvm
```

## Some Observations With kubectl

When a VM is started via `virtctl start testvm` above, a `virtlauncher` is started in
the default namespace:

```
$ kubectl get po
virt-launcher-testvm-9hw7n                0/2       ContainerCreating   0          5s

$ kubectl get po
NAME                                      READY     STATUS      RESTARTS   AGE
virt-launcher-testvm-9hw7n                2/2       Running     0          117s

$ kubectl describe vms testvm|grep -i runn
...
  Running:  true
```

The IP address of the VM is the IP address of the virt-launcher pod (note the IP address
10.233.67.75):

```
$ kubectl get po -o wide|grep virt
virt-launcher-testvm-9hw7n                2/2       Running     0          4m20s     10.233.67.75     kube-test-10
```

That IP address 10.233.67.75 is reachable from the host where the Pod/VM are running:

```
$ ssh kube-test-10

ubuntu@kube-test-10:~$ ping 10.233.67.75
PING 10.233.67.75 (10.233.67.75) 56(84) bytes of data.
64 bytes from 10.233.67.75: icmp_seq=1 ttl=64 time=0.368 ms
^C
--- 10.233.67.75 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.368/0.368/0.368/0.000 ms

ubuntu@kube-test-10:~$ ssh cirros@10.233.67.75
The authenticity of host '10.233.67.75 (10.233.67.75)' can't be established.
ECDSA key fingerprint is SHA256:JJQ6r4mBkmSm/BuXbcgt+6xhVV+6WotC05brOGjEw+k.
Are you sure you want to continue connecting (yes/no)? yes
Warning: Permanently added '10.233.67.75' (ECDSA) to the list of known hosts.
cirros@10.233.67.75's password:
$ ip -4 addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue qlen 1
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast qlen 1000
    inet 10.233.67.75/32 brd 10.255.255.255 scope global eth0
       valid_lft forever preferred_lft forever
$
```

As such, we can use the same technique described above with our ssh_config file to reach
VMs created by kubevirt in our kube-mini-cloud.

Looking at the docker containers on the host to see what's going on under the hood (note I filtered
out all the other pods and removed some unneeded text from the output for readability):

```
root@kube-test-10:/home/ubuntu# docker ps |grep -v pause|grep -v kuul-stage| grep -v hyperkube|grep -v load-image|grep -v calico| grep -v node-exporter|grep -v proxy-kube
CONTAINER ID        IMAGE                                      COMMAND                  CREATED             NAMES
0d8005fcc748        1dbd9c7faf63                               "/usr/bin/virt-launc…"   12 minutes ago      k8s_compute_virt-launcher-testvm-9hw7n_default_1a4ea9a4-a687-11e9-b2b8-fa163eb8592c_0
073d789f6aba        kubevirt/cirros-registry-disk-demo         "/entry-point.sh"        12 minutes ago      k8s_volumerootfs_virt-launcher-testvm-9hw7n_default_1a4ea9a4-a687-11e9-b2b8-fa163eb8592c_0
d30437585fc7        kubevirt/virt-handler                      "virt-handler --port…"   26 hours ago        k8s_virt-handler_virt-handler-qfrpp_kubevirt_10c195e3-a5ad-11e9-8ea2-fa163e53e0e7_0
d706583c48a5        kubevirt/virt-operator                     "virt-operator --por…"   26 hours ago        k8s_virt-operator_virt-operator-7b5488c788-b5dlj_kubevirt_df70b49d-a5ac-11e9-8ea2-fa163e53e0e7_0
```

You can see there is a qemu process on the host:

```
root@kube-test-10:/home/ubuntu# ps aux|grep qemu
root     138295  0.1  0.0 2687812 52364 ?       Ssl  17:48   0:00 /usr/bin/virt-launcher --qemu-timeout 5m --name testvm --uid 8efc786a-a689-11e9-b2b8-fa163eb8592c --namespace default --kubevirt-share-dir /var/run/kubevirt --ephemeral-disk-dir /var/run/kubevirt-ephemeral-disks --readiness-file /var/run/kubevirt-infra/healthy --grace-period-seconds 45 --hook-sidecars 0 --less-pvc-space-toleration 10
root     138365  0.2  0.0 2983252 56340 ?       Sl   17:48   0:00 /usr/bin/virt-launcher --qemu-timeout 5m --name testvm --uid 8efc786a-a689-11e9-b2b8-fa163eb8592c --namespace default --kubevirt-share-dir /var/run/kubevirt --ephemeral-disk-dir /var/run/kubevirt-ephemeral-disks --readiness-file /var/run/kubevirt-infra/healthy --grace-period-seconds 45 --hook-sidecars 0 --less-pvc-space-toleration 10 --no-fork true
uuidd    138713  6.6  0.1 5007076 101612 ?      Sl   17:49   0:21 /usr/bin/qemu-system-x86_64 -name guest=default_testvm,debug-threads=on -S -object ...
```

## Try the fedora image

User=fedora, password=fedora

```
$ kubectl get virtualmachineinstance
NAME          AGE       PHASE     IP             NODENAME
vmi-fedora    1h        Running   10.233.67.95   kube-test-10
vmi-fedora2   1h        Running   10.233.67.96   kube-test-10

$  kubectl get vmis
NAME          AGE       PHASE     IP             NODENAME
vmi-fedora    1h        Running   10.233.67.95   kube-test-10
vmi-fedora2   1h        Running   10.233.67.96   kube-test-10
```

## Create an Custom Image from My Image

We have a custom ubuntu image that was custom built using Disk Image Builder (DIB) and
it contains various tools including minikube.  We use this image on Openstack to build
instances (VMs) via Nodepool; Zuul consumes these VMs to run CI jobs.
I would like to take this image and run it under kubevirt.

Using the [container-register-disks](https://github.com/kubevirt/kubevirt/blob/master/docs/container-register-disks.md)
doc, I did this on my kube-test-10 k8s host.

```
# Resize the image to give the VM 15G of disk space
qemu-img resize ubuntu-xenial-minikube-0000000045-20G.qcow2 +15G

# Create the Dockerfile with container-disk wrapper
cat << END > Dockerfile
FROM kubevirt/container-disk-v1alpha
ADD ubuntu-xenial-minikube-0000000045.qcow2 /disk <-- this is the DIB image
END

# Build the image (I build it on the host so I don't have to push)
sudo docker build -t kube-cm/ubuntu-xenial-minikube:0.45 .
```

This build the docker image; the image resides locally on kube-test-10 so it's ready to be pulled.
I then created files/custom-mini.yaml which is just like the fedora yaml except it uses my
custom imge.  I then did:

```
kubectl apply -f files/custom-mini.yaml
```

I then got a VM using my image.

## Some Things to Read

Still need to figure out how to create my own custom VM images.

https://github.com/kubevirt/kubevirt/tree/master/docs
https://kubevirt.io/api-reference/

How to use PV/PVCs as the VM's disk:
  https://github.com/kubevirt/kubevirt/blob/master/docs/direct-pv-disks.md

Use filesystem as backing store:
  https://github.com/kubevirt/kubevirt/blob/master/docs/filesystem-pv-disks.md

Read about debugging for kubevirt:
  https://github.com/kubevirt/kubevirt/blob/master/docs/debugging.md

Read this on how to interact with the VMs:
  https://github.com/kubevirt/user-guide/blob/master/architecture/virtual-machine.adoc#kubectl-commandline-interactions

Use multus to connect my VMs to multiple networks:
  https://github.com/intel/multus-cni
  https://github.com/kubevirt/user-guide/blob/master/creating-virtual-machines/interfaces-and-networks.adoc

List of VMs in the repo:
  https://github.com/kubevirt/kubevirt/blob/master/docs/devel/guest-os-info.md

## Things I still need to get working

* Ability to put an arbitrary public key in the VM's .ssh/authorized_keys
  * See https://github.com/kubevirt/user-guide/blob/master/creating-virtual-machines/startup-scripts.adoc
    * Look for ssh-authorized-keys example
* Use PVs as the VM's backing disk
  * Maybe this is related: https://github.com/kubevirt/user-guide/blob/master/administration/image-upload.adoc
* VMs need 20G disk:
  * maybe this: https://github.com/kubevirt/user-guide/blob/master/creating-virtual-machines/disks-and-volumes.adoc#hostdisk
  * from: https://github.com/kubevirt/kubevirt/blob/master/docs/devel/virtual-machine.md

```
apiVersion: kubevirt.io/v1alpha2
kind: VirtualMachine
metadata:
  name: myvm
spec:
  running: false
  template:
    metadata:
      labels:
        my: label
    spec:
      domain:
        resources:
          requests:
            memory: 8Mi
        devices:
          disks:
          - name: disk0
            volumeName: mypcv  <-- the disk will be a PVC
      volumes:
        - name: mypvc
          persistentVolumeClaim:
            claimName: myclaim
```
* Create a Kubernetes cluster using VMs created by kubevirt
  * Create a Pod that runs kubespray that contains the inventory of VMs created by kubevirt
* Restrict to only kube-test-10 (which is a big BM that can run lots of VMs)
  * See https://github.com/kubevirt/user-guide/pull/261
* Startup VMs using my custom images:
  * https://github.com/kubevirt/kubevirt/blob/master/docs/container-register-disks.md


## Troubleshooting

I saw this after I had done a `kubectl delete -f custom-minikube.yaml`; I expected to delete the VM.
I was then unable to apply custom-minikube.yaml because of it.

```
$ kubectl get vmis
NAME            AGE       PHASE     IP              NODENAME
vmi-fedora      10h       Running   10.233.67.95    kube-test-k8s-node-10
vmi-fedora2     10h       Running   10.233.67.96    kube-test-k8s-node-10
vmi-minikube    7m        Failed    10.233.67.111   kube-test-k8s-node-10
vmi-minikube1   27s       Running   10.233.67.112   kube-test-k8s-node-10
```

I was able to mitigate this by deleting the vmi:

```
$ kubectl delete vmi vmi-minikube
virtualmachineinstance.kubevirt.io "vmi-minikube" deleted

$ kubectl get vmis
NAME            AGE       PHASE     IP              NODENAME
vmi-fedora      10h       Running   10.233.67.95    kube-test-k8s-node-10
vmi-fedora2     10h       Running   10.233.67.96    kube-test-k8s-node-10
vmi-minikube1   44s       Running   10.233.67.112   kube-test-k8s-node-10
```

## Trying to make a bigger disk

Resize the image using qemu:

```
$ qemu-img resize ubuntu-xenial-minikube-0000000045-20G.qcow2 +15G
```

Then rebuild your image container using this new disk.

Then when you go into the VM, you will see the disk is bigg:

```
ubuntu@ubuntu:~$ df -h
Filesystem      Size  Used Avail Use% Mounted on
udev            3.7G     0  3.7G   0% /dev
tmpfs           761M  8.7M  753M   2% /run
/dev/vda1        17G  2.6G   14G  16% /        <-- this used to be 4G in size
tmpfs           3.8G     0  3.8G   0% /dev/shm
tmpfs           5.0M     0  5.0M   0% /run/lock
tmpfs           3.8G     0  3.8G   0% /sys/fs/cgroup
```

See files/disk.yaml using host disk.  The disk is there but you have to mount it.

```
root@ubuntu:/home/ubuntu# fdisk -l
Disk /dev/vda: 3 GiB, 3225681920 bytes, 6300160 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: dos
Disk identifier: 0xbcef8221

Device     Boot Start     End Sectors Size Id Type
/dev/vda1  *     2048 6298111 6296064   3G 83 Linux


Disk /dev/vdb: 20 GiB, 21474836480 bytes, 41943040 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
root@ubuntu:/home/ubuntu#
```

## Some Disk Images

The [Ubuntu 16.04 minimal](https://cloud-images.ubuntu.com/minimal/releases/xenial/release-20190628/ubuntu-16.04-minimal-cloudimg-amd64-disk1.img)
image seems to work.  I get it via:

```
$ wget https://cloud-images.ubuntu.com/minimal/releases/xenial/release-20190628/ubuntu-16.04-minimal-cloudimg-amd64-disk1.img
$ qemu-img resize ubuntu-16.04-minimal-cloudimg-amd64-disk1.img +20G

$ cat Dockerfile
FROM kubevirt/container-disk-v1alpha
ADD ubuntu-16.04-minimal-cloudimg-amd64-disk1.img /disk

$ sudo docker build -t kube-cm/ubuntu-16.04-minimal:0.20 .
$ sudo docker push -t kube-cm/ubuntu-16.04-minimal:0.20 .

$ kubectl apply -f ubuntu-16.04-minimal.yaml
```

NOTE: This [cloud config tutorial](https://www.digitalocean.com/community/tutorials/how-to-use-cloud-config-for-your-initial-server-setup)
was useful to help me get the cloudinit setup.




# How to Create a Kube Stack

We will stand up a "kube stack".  I define a "Kube Stack" as a Kubernetes cluster
(I call mine
"kube-stack) built
with [kubespray](https://github.com/kubernetes-incubator/kubespray) with Pods
and [kubevirt](https://github.com/kubevirt) VMs on it.
We will also add an on-cluster container registry so we can store all
of our images locally.

In my case, we will use kube-stack to build Pods and VMs that we can ssh into
and run tests including:

* kubespray tests
* CI tests that require a full VM (I hope to run tests in some automated
  way to supplement our overworked CI system).
* CD tests on Pods that will eventually run on a
  [Kuul Periodic System](https://github.com/dperique/Kuul_periodics)

We will also use it (in an experimenal/exploratory way) to give out VMs for
aribitrary uses.  I'm curious how to can be used to supplement our Openstack
cluster for general VM use.

It reminds of much of what we use Openstack for but also has the concept of Pods.
Hence, the name "Kube Stack".

## Create the Kubernetes cluster

Get some properly sized baremetal servers and 
[prepare them](https://github.com/dperique/kubespray_preparation) for kubespray. I
went with 5 servers with 56 cores and 256G RAM each for a Kubernetes cluster with
a total of 280 cores and 1.2 Terabytes of RAM).  If things go well, I plan to add
more nodes.

In your group_vars/all, set `registry_enabled: true` so that kubespray
will build a container registry on the Kubernetes cluster.

Run kubespray (I'm using kubespray v2.7.0).

When it finishes, the `registry` pod in the kube-system namespace will be in
Pending state because there is no PVC for it -- we will fix this in the next
section.

## Setup the storage for your container registry

Pick a Kubernetes node to store your images.  On that node, create a subdir to hold
the container registry data, then create the PV and PVC for it:

```
mkdir /opt/registry-data
kubectl apply -f registry-pvc.yaml 
kubectl apply -f registry-pv.yaml 
```

NOTE: the yaml files are in the `source` subdir of this repo.

Delete the Pending `registry` pod.  After it restarts, it will be in Running
state.

Refer to the kubespray doc for more information about
[kubernetes-apps/registry](https://github.com/kubernetes-sigs/kubespray/tree/master/roles/kubernetes-apps/registry).

## Create a Pod image

You can create any Pod you like (there are many examples out there).  In my case,
I want to build one using this [Dockerfile](https://github.com/dperique/kube-mini-cloud/blob/master/source/Dockerfile).

First get a proper Docker file and put it in some directory where you can build the image.

You can build the docker container in two ways: 1) on one of the Kubernetes hosts
and 2) on another machine (but that machine needs kubectl access to the kube-stack Kubernetes
cluster.

* Method 1: On one of the Kubernetes hosts:

  * ssh to one of your Kubernetes hosts and build the docker image and tag
    it using our local container registry:

    ```
    sudo docker build -t localhost:5000/kube-stack/ubuntu-16.04-ssh:0.1 .
    ```

* Method 2: On another machine that has kubectl access to the kube-stack Kubernetes cluster:

  * On your the machine where you want to build your docker image, do this:
    ```
    POD=$(kubectl get pods --namespace kube-system -l k8s-app=registry \
            -o template --template '{{range .items}}{{.metadata.name}} {{.status.phase}}{{"\n"}}{{end}}' \
            | grep Running | head -1 | cut -f1 -d' ')

    kubectl port-forward --namespace kube-system $POD 5000:5000 &
    ```
    NOTE: the above is copied/pasted from the kubespray document mention earlier and makes
    the container registry port 5000 available on the localhost.

    Build your image as in Method 1:

    ```
    sudo docker build -t localhost:5000/kube-stack/ubuntu-16.04-ssh:0.1 .
    ```

After building your Docker image using one of the above methods, do this to push your docker image
to the local container registry (in my case, I'm calling my image "dperique/cont:0.1"):

```
sudo docker push localhost:5000/kube-stack/ubuntu-16.04-ssh:0.1
```

In your podspec, specify your image as:

```
image: localhost:5000/kube-stack/ubuntu-16.04-ssh:0.1 .
```

## Create VM Images

I have a machine called "nodepool" that runs nodepool and Disk Image Builder.  This
machine builds my custom images used for running CI tests and creates qcow2 files.
I will copy my custom images from
the nodepool machine and resize them, using `qemu-image`, to 20G (so when the VM boots,
it has 20G of disk).

You can create VM images using any of the image types supported by kubevirt.
Refer to the [example above](https://github.com/dperique/kube-mini-cloud#create-an-custom-image-from-my-image).

Resize the images as mentioned above:

```
qemu-img resize ubuntu-16.04-minimal-cloudimg-amd64-disk1.img +20G
qemu-img resize ubuntu-xenial-minikube-0000000045.qcow2 +20G
qemu-img resize ubuntu-bionic-minikube-0000000154.qcow2 +20G
```

I will copy these images to one of my kube-stack nodes (node 5) and build the
kubevirt docker images.  Here are my three Dockerfiles for the three images I
intend to use:

```
ubuntu@kube-stack-k8s-node-5:~$ cat Dockerfile.16.04-min
FROM kubevirt/container-disk-v1alpha
ADD ubuntu-16.04-minimal-cloudimg-amd64-disk1.img /disk

ubuntu@kube-stack-k8s-node-5:~$ cat Dockerfile.xenial-minikube
FROM kubevirt/container-disk-v1alpha
ADD ubuntu-xenial-minikube-0000000045.qcow2 /disk

ubuntu@kube-stack-k8s-node-5:~$ cat Dockerfile.bionic-minikube
FROM kubevirt/container-disk-v1alpha
ADD ubuntu-bionic-minikube-0000000154.qcow2 /disk
```

Build each image (I include the Pod image from above for completeness):

```
rm -f Dockerfile
ln -s Dockerfile.16.04-min Dockerfile
sudo docker build -t localhost:5000/kube-stack/ubuntu-16.04-minimal:072019 .

rm -f Dockerfile
ln -s Dockerfile.xenial-minikube Dockerfile
sudo docker build -t localhost:5000/kube-stack/ubuntu-xenial-minikube:072019 .

rm -f Dockerfile
ln -s Dockerfile.bionic-minikube Dockerfile
sudo docker build -t localhost:5000/kube-stack/ubuntu-bionic-minikube:072019 .

rm -f Dockerfile
ln -s Dockerfile.16.04-ssh-Pod Dockerfile
sudo docker build -t localhost:5000/kube-stack/ubuntu-16.04-ssh:0.1 .
```

Push the images to the local container registry as mentioned in the previous section.

```
sudo docker push localhost:5000/kube-stack/ubuntu-16.04-minimal:072019
sudo docker push localhost:5000/kube-stack/ubuntu-xenial-minikube:072019
sudo docker push localhost:5000/kube-stack/ubuntu-bionic-minikube:072019
sudo docker push localhost:5000/kube-stack/ubuntu-16.04-ssh:0.1
```
