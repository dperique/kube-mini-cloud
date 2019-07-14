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
