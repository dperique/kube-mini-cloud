# Make 5 VMs for a CI Kubernetes cluster.
#
aFile="wrig-ubuntu-16.04-minimal.yaml"
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-$i/"| kubectl apply -f - ; done
