# How to Create a Kube Stack

We will stand up a "Kube Stack".  I define a "Kube Stack" as a Kubernetes cluster
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

Pick a Kubernetes node (I use node 5) to store your images.  On that node, create a subdir to hold
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
