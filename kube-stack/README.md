# How to Create a Kube Stack

## Definition of "Kube Stack"

A "Kube Stack" is a Kubernetes cluster built
with tools such as [kubespray](https://github.com/kubernetes-incubator/kubespray) populated
with your custom Pods and VMs running inside Pods using [kubevirt](https://github.com/kubevirt).
We will also add an on-cluster container registry so we can store all
of our Pod and VM images locally.

The name is a play on some Kubernetes and Openstack basic functionality combined
into one place.  I like to run my testing scenarios in Pods (for their lightweight
characteristics) but for scenarios that require applications (e.g., minikube) that
cannot run in a Pod, I need VMs.  The way I would do this testing is to create a
Kubernetes cluster for my Pods and then run my VMs using Openstack.  This has worked
well in the past but I like the idea of combining them in one envirnoment.

## The use-case for Kube Stack

In my case, we will use kube-stack to build Pods and VMs that we can ssh into
and do things like:

* Kubernetes tests including building "micro kube clusters" running on kubevirt VMIs (VMs)
  (i.e., kube in kube)
  * We run kubespray on a Pod to install Kubernetes onto 5 kubevirt VMIs (VMs)
  * We can then run these Kubernetes tests:
    * Kubernetes/docker upgrades/downgrades
    * Kube-ops runbooks:
      * Adding/removing Kubernetes nodes
      * Recovering or replacing broken Kubernetes nodes
    * Application installations, running tests on those applications
  * See [Creating Micro Kubernetes Clusters using Kubespray](https://github.com/dperique/kube-mini-cloud/blob/master/kube-stack/README_micro_kube.md)
* CI tests that require a full VM (I hope to run tests in some automated
  way to supplement our overworked CI system).
  * Developing, testing, and debugging of the CI test scripts
* CD tests on Pods that will eventually run on a
  [Kuul Periodic System](https://github.com/dperique/Kuul_periodics)
  * Developing, testing, and debugging of the CD scripts

We will also use it (in an experimenal/exploratory way) to give out VMs for
aribitrary uses.  I'm curious how to can be used to supplement our Openstack
cluster for general VM use.

## Create the Kube Stack Kubernetes cluster

In my case, I use kubespray v2.7.0.  You can use any tool to build the Kubernetes cluster
including kubeadm, etc.

Get some properly sized baremetal servers and 
[prepare them](https://github.com/dperique/kubespray_preparation) for kubespray. I
went with 5 servers with 56 cores and 256G RAM each for a Kubernetes cluster with
a total of 280 cores and 1.2 Terabytes of RAM).  If things go well, I plan to add
more nodes.

On the hosts that will be running VMs using kubevirt
[Enable nested virtualization](https://docs.fedoraproject.org/en-US/quick-docs/using-nested-virtualization-in-kvm/index.html)
like this:

```
  sudo su
  modprobe -r kvm_intel
  modprobe kvm_intel nested=1
  vi /etc/modprobe.d/kvm.conf
    options kvm_intel nested=1  <-- adding this ensures it's set on boot
```

In your group_vars/all, set `registry_enabled: true` so that kubespray
will build a container registry on the Kubernetes cluster.

Run kubespray (I'm using kubespray v2.7.0) on your baremetal servers.

When kubespray finishes, the `registry` pod in the kube-system namespace will be in
Pending state because there is no PVC for it -- we will fix this in the next
section.

## Setup the storage for your container registry

Pick a Kubernetes node (I use node 5) to store your images.  On that node, create a subdir to hold
the container registry data, then apply the PV and PVC yamls to create a PV and PVC for the
"registry" Pod:

```
ssh (hostname of your node 5) ; mkdir /opt/registry-data
kubectl apply -f files/registry-pvc.yaml
kubectl apply -f files/registry-pv.yaml
```

NOTE: the yaml files are in the `kube-stack/files` subdir of this repo.  The yaml
for the PV has kube-stack-node-5 hardcoded in it so change it if you used a different
name.

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

Here is an example of building a Docker image for Kuul Zuul Periodic jobs:

```
git clone git@github.someco.com:Someplace/Kuul_Zuul_periodics.git
rm -f Dockerfile
ln -s Dockerfile.kuul_zuul_periodics_ssh_k8s Dockerfile
sudo docker build -t localhost:5000/kube-stack/kuul_zuul_periodics:v2.8b-ssh .
sudo docker push localhost:5000/kube-stack/kuul_zuul_periodics:v2.8b-ssh
```

Examples of building VMI images using the Dockerfile samples in this repo:

```
rm -f Dockerfile
ln -s Dockerfile.xenial Dockerfile
sudo docker build -t localhost:5000/kube-stack/ubuntu-xenial:072019 .
sudo docker push localhost:5000/kube-stack/ubuntu-xenial:072019

rm -f Dockerfile
ln -s Dockerfile.bionic Dockerfile
sudo docker build -t localhost:5000/kube-stack/ubuntu-bionic:072019 .
sudo docker push localhost:5000/kube-stack/ubuntu-bionic:072019
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

## Install kubevirt on kube-stack

Install the version 0.19 of kubevirt:

```
kubectl config use-context kube-stack
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v0.19.0/kubevirt-operator.yaml
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v0.19.0/kubevirt-cr.yaml
kubectl -n kubevirt wait kv kubevirt --for condition=Ready
```

The last line waits for the `kubevirt` of type `kv` to be in Ready state.

Optional: Keep
[patch virt-handler](https://github.com/kubevirt/user-guide/blob/master/administration/intro.adoc#restricting-virt-handler-daemonset)
in mind in case you want to patch the virt-handler daemonset so it will only run kubevirt on
certain Kubernetes nodes. Pasted here for convenience:

For example, to restrict the DaemonSet to only nodes with the "region=primary" label:

```
kubectl patch ds/virt-handler -n kubevirt -p '{"spec": {"template": {"spec": {"nodeSelector": {"region": "primary"}}}}}'
```

You should eventually see:

```
$ kubectl -n kubevirt get po,ds,kv
NAME                                  READY     STATUS    RESTARTS   AGE
pod/virt-api-6fb795dbd9-br8gp         1/1       Running   0          2m32s
pod/virt-api-6fb795dbd9-jsc8f         1/1       Running   0          2m32s
pod/virt-controller-7cc5b46b9-kdlcp   1/1       Running   0          2m7s
pod/virt-controller-7cc5b46b9-p62hr   1/1       Running   0          2m7s
pod/virt-handler-br8bw                1/1       Running   0          2m7s
pod/virt-handler-ml9zj                1/1       Running   0          2m7s
pod/virt-handler-r7j9c                1/1       Running   0          2m7s
pod/virt-handler-r864k                1/1       Running   0          2m7s
pod/virt-handler-zc5jm                1/1       Running   0          2m7s
pod/virt-operator-7b5488c788-b9v5r    1/1       Running   0          2m53s
pod/virt-operator-7b5488c788-r7z4q    1/1       Running   0          2m53s

NAME                                DESIRED   CURRENT   READY     UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
daemonset.extensions/virt-handler   5         5         5         5            5           <none>          2m7s

NAME                            AGE       PHASE
kubevirt.kubevirt.io/kubevirt   2m        Deployed
```

In case you ever need to un-install kubevirt, do this:

```
$ kubectl delete -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-cr.yaml
$ kubectl delete -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
```

Install [krew plugin](https://github.com/kubernetes-sigs/krew/#installation) so you can get virtctl:

```
set -x; cd "$(mktemp -d)" &&
  curl -fsSLO "https://storage.googleapis.com/krew/v0.2.1/krew.{tar.gz,yaml}" &&
  tar zxvf krew.tar.gz &&
  ./krew-"$(uname | tr '[:upper:]' '[:lower:]')_amd64" install \
    --manifest=krew.yaml --archive=krew.tar.gz
```

Add this to your ~/.bashrc then restart your shell:

```
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
```

Install virtctl:

```
$ kubectl krew install virt
Updated the local copy of plugin index.
Installing plugin: virt
CAVEATS:
\
 |  virt plugin is a wrapper for virtctl originating from the KubeVirt project. In order to use virtctl you will
 |  need to have KubeVirt installed on your Kubernetes cluster to use it. See https://kubevirt.io/ for details
 |  
 |  Run
 |  
 |    kubectl virt help
 |  
 |  to get an overview of the available commands
 |  
 |  See
 |  
 |    https://kubevirt.io/user-guide/docs/latest/using-virtual-machines/graphical-and-console-access.html
 |  
 |  for a usage example
/
Installed plugin: virt
```

Now you can use virtctl like this:

```
kubectl virt help
```

## Create Namespaces and VMs

We will organize our VMs by namespace.

We are creating VMs that we can use to install various things on including some stuff
we used from the [bonnyci](https://github.com/BonnyCI) project.

```
kubectl create ns k8s-test
kubectl create ns demo
kubectl create ns zuul-ci
kubectl create ns kuul-pods

kubectl apply -f vmi-fedora.yaml
kubectl -n demo get po -o wide

$ kubectl get vmi -n demo
NAME         AGE   PHASE     IP              NODENAME
vmi-fedora   54s   Running   10.233.71.222   kube-stack-k8s-node-2

$ kubectl virt console vmi-fedora -n demo

$ kubectl get po -n demo -o wide
NAME                             READY   STATUS    RESTARTS   AGE     IP              NODE
virt-launcher-vmi-fedora-l7cjj   2/2     Running   0          6m20s   10.233.71.222   kube-stack-k8s-node-2

$ kubectl delete po virt-launcher-vmi-fedora-l7cjj -n demo
pod "virt-launcher-vmi-fedora-l7cjj" deleted


$ kubectl get vmi -n zuul-ci
NAME             AGE   PHASE     IP              NODENAME
vmi-xenial-mk1   26s   Running   10.233.87.201   kube-stack-k8s-node-5

$ kubectl get po -o wide -n zuul-ci
NAME                                 READY   STATUS    RESTARTS   AGE   IP              NODE
virt-launcher-vmi-xenial-mk1-ddb62   2/2     Running   0          32s   10.233.87.201   kube-stack-k8s-node-5

$ kubectl apply -f ubuntu-xenial-minikube.yaml
$ kubectl apply -f ubuntu-bionic-minikube.yaml

$ kubectl get vmi --all-namespaces
NAMESPACE   NAME             AGE   PHASE     IP              NODENAME
zuul-ci     vmi-bionic-mk1   3m    Running   10.233.71.223   kube-stack-k8s-node-2
zuul-ci     vmi-xenial-mk1   10m   Running   10.233.87.201   kube-stack-k8s-node-5



$ kubectl apply -f kuul-secrets-wrig.yaml -n kuul-pods
secret/kuul-secrets created


$ ./makeCont.sh create dp-bonny1 default

      dp-bonny1   10.233.35.187

alias sshp="ssh -F /home/bonnyci/git/kube-mini-cloud/kube-stack/files/ssh_config"

$ cat ssh_config
# This is a generated file
Host kube-stack-4
  HostName 10.171.203.72
  User ubuntu
  IdentityFile ~/.ssh/kube-stack.rsa

Host dp-bonny1
  User bonnyci
  HostName 10.233.35.187
  StrictHostKeyChecking no
  ProxyCommand ssh -A -W %h:%p kube-stack-4
  IdentityFile ~/.ssh/junk.id_rsa

$ alias sshp="ssh -F /home/bonnyci/git/kube-mini-cloud/kube-stack/files/ssh_config"

$ sshp dp-bonny1
Welcome to Ubuntu 16.04.6 LTS (GNU/Linux 4.4.0-154-generic x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/advantage
Last login: Sat Jul 20 18:03:41 2019 from 10.171.203.72
To run a command as administrator (user "root"), use "sudo <command>".
See "man sudo_root" for details.

bonnyci@dp-bonny1:~$ logout

$ bash -x makeVM.sh
+ aFile=wrig-ubuntu-16.04-minimal.yaml
+ for i in '{1..5}'
+ cat wrig-ubuntu-16.04-minimal.yaml
+ kubectl apply -f -
+ sed s/AVALUE/ci-kube-1/
virtualmachineinstance.kubevirt.io/ci-kube-1 created
+ for i in '{1..5}'
+ kubectl apply -f -
+ sed s/AVALUE/ci-kube-2/
+ cat wrig-ubuntu-16.04-minimal.yaml
virtualmachineinstance.kubevirt.io/ci-kube-2 created
+ for i in '{1..5}'
+ kubectl apply -f -
+ sed s/AVALUE/ci-kube-3/
+ cat wrig-ubuntu-16.04-minimal.yaml
virtualmachineinstance.kubevirt.io/ci-kube-3 created
+ for i in '{1..5}'
+ cat wrig-ubuntu-16.04-minimal.yaml
+ sed s/AVALUE/ci-kube-4/
+ kubectl apply -f -
virtualmachineinstance.kubevirt.io/ci-kube-4 created
+ for i in '{1..5}'
+ kubectl apply -f -
+ sed s/AVALUE/ci-kube-5/
+ cat wrig-ubuntu-16.04-minimal.yaml
virtualmachineinstance.kubevirt.io/ci-kube-5 created


$ for i in {1..5} ; do ./makeCont.sh create dp-bonny$i default ; done

service/dp-bonny1 unchanged
pod/dp-bonny1 configured

      dp-bonny1   10.233.35.187

...
alias sshp="ssh -F /home/bonnyci/git/kube-mini-cloud/kube-stack/files/ssh_config"

$ kubectl get vmi --all-namespaces
NAMESPACE   NAME             AGE   PHASE     IP              NODENAME
k8s-test    ci-kube-1        4m    Running   10.233.82.141   kube-stack-k8s-node-1
k8s-test    ci-kube-2        4m    Running   10.233.87.96    kube-stack-k8s-node-4
k8s-test    ci-kube-3        4m    Running   10.233.82.142   kube-stack-k8s-node-1
k8s-test    ci-kube-4        4m    Running   10.233.71.224   kube-stack-k8s-node-2
k8s-test    ci-kube-5        4m    Running   10.233.114.99   kube-stack-k8s-node-3
zuul-ci     vmi-bionic-mk1   2h    Running   10.233.71.223   kube-stack-k8s-node-2
zuul-ci     vmi-bionic1      8m    Running   10.233.114.98   kube-stack-k8s-node-3
zuul-ci     vmi-xenial-mk1   2h    Running   10.233.87.201   kube-stack-k8s-node-5
zuul-ci     vmi-xenial1      13m   Running   10.233.87.95    kube-stack-k8s-node-4

$ kubectl get po -n kuul-pods
NAME        READY   STATUS    RESTARTS   AGE
dp-bonny1   1/1     Running   0          117m
dp-bonny2   1/1     Running   0          104s
dp-bonny3   1/1     Running   0          103s
dp-bonny4   1/1     Running   0          101s
dp-bonny5   1/1     Running   0          98s
```

## Commentary

Here are a few things I found worthy to mention:

* When you run VMs, especially many VMs, there will be network contention as there
  would be for any cloud.  For example, when you run 1 VM to run kubespray and
  another 5 VMs to receive kubespray, you will get traffic from the first VM to all
  5 VMs simultaneously (due to ansible).  This works, but I believe because of
  ip in ip in ip in ip (i.e., ip-in-ip x 2), the network performance will be a little
  slower.
    * If you're going to do something like this, I suggest, moving all 6 VMs onto
      the same k8s node.  This way, there is only only ip-in-ip.  You can think of
      this as VM affinity similar to pod affinity (but with VMIs which are also pods).
    * To keep VMs on the same k8s node, make a label on that k8s node and then use
      a nodeSelector when creating the VMI.  For example, I label one node with
      `kubectl label node (nodeName) owner=dperiquet` and the use this nodeSelector:

      ```
      spec:
        nodeSelector:
          owner: "dperiquet"
        domain:
          devices:
            disks:
            - disk:
      ...
      ```
* How to expose a VM as a service so you can ssh to it outside of the kube-stack
  k8s cluster (I show both using kubectl virt subcommand and virtctl commands and in my case,
  I have to VMs in the "zuul-ci" namespace called "xenial1" and "xenial-mk1"):

  ```
  $ kubectl virt expose virtualmachineinstance vmi-xenial1 --name xenial1-ssh --type NodePort --port 22 -n zuul-ci
  service xenial1-ssh successfully exposed for virtualmachineinstance vmi-xenial1

  $ virtctl expose virtualmachineinstance vmi-xenial-mk1 --name xenial-mk1-ssh --type NodePort --port 22 -n zuul-ci
  Service xenial-mk1-ssh successfully exposed for virtualmachineinstance vmi-xenial-mk1

  $ kubectl get svc -n zuul-ci
  NAME             TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
  xenial-mk1-ssh   NodePort   10.233.12.238   <none>        22:30366/TCP   24s
  xenial1-ssh      NodePort   10.233.34.53    <none>        22:30625/TCP   6m18s

  $ telnet x.x.x.x 30625
  Trying 10.171.203.72...
  Connected to 10.171.203.72.
  Escape character is '^]'.
  SSH-2.0-OpenSSH_7.2p2 Ubuntu-4ubuntu2.8
  ```

* If you want to specify the port for the VM, use this as specifying the nodeport in virtctl
  is apparently not supported (my goal was to map nodeport 30022 as port 22 on the "xenial-weave
  VM):

  ```
  $ cat vm-nodeport.yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: xenial-weave
    namespace: k8s-test
  spec:
    type: NodePort
    ports:
      - port: 22
        nodePort: 30022
        protocol: TCP
    selector:
      kubevirt.io/domain: xenial-weave
      special: vmi-xenial-weave

  $ kubectl apply -f vm-nodeport.yaml
  service/xenial-weave created

  $ kubectl get svc -n k8s-test
  NAME           TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
  xenial-weave   NodePort   10.233.11.91   <none>        22:30022/TCP   3m22s
  ```

* How to expose a Pod to outside the kube-stack cluster on a nodeport: the short answer
  is just make a nodePort service (in this case, I wanted one of my pods called "dp-kube4"
  to be reachable via nodeport 30422 for ssh):

  ```
  apiVersion: v1
  kind: Service
  metadata:
    name: dp-kube4
    namespace: kuul-pods
  spec:
    type: NodePort
    ports:
      - port: 22
        nodePort: 30422
        protocol: TCP
    selector:
      app: dp-kube4-ssh
  ```

* If a k8s node reboots, and there are VMs on that node, those VMs will go into "Failed"
  state.  Due to how we setup the VMs using the images described above, if your VM goes
  into "Failed" state, the VM is gone and whatever data on it is gone.

  To recover, delete the VM by doing `kubectl delete -f xx.yaml` where xx.yaml is the yaml
  used to create the VM.
