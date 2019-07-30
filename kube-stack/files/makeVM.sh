# Make 5 VMs for a CI Kubernetes cluster.
#
aFile="wrig-ubuntu-16.04-minimal.yaml"
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kubeadm$i/"| kubectl apply -f - ; done
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-v27-$i/"| kubectl apply -f - ; done
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-v24-$i/"| kubectl apply -f - ; done
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-vv$i/"| kubectl apply -f - ; done
