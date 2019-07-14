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
docker build -t kuul_ssh:v1 .
docker save -o /tmp/o.tar kuul_ssh:v1
tar czvf ./t.tgz ./o.tar
for i in IP1 IP2 IP3 ; do
  scp -i junk.rsa t.tgz ubuntu@$i:/tmp
  ssh -i junk.rsa ubuntu@$i  "cd /tmp ; tar xzvf /tmp/t.tgz"
  ssh -i junk.rsa ubuntu@$i  "cd /tmp ; sudo docker load -i o.tar"
done
```

The above script loads the images directly onto the docker instance of those nodes.  This
way, when you start up the Pod, it won't need to goto a container registry because it will
already be present.  You will have to set the imagePullPolicy to IfNotPresent.

## Creating the VMs

We will use kubevirt which requires some setup -- more on that later.
