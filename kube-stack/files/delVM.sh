# Delete 5 VMs for a CI Kubernetes cluster.
#
aFile="wrig-ubuntu-16.04-minimal.yaml"
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kubeadm$i/"| kubectl delete -f - ; done
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-v27-$i/"| kubectl delete -f - ; done
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-v24-$i/"| kubectl delete -f - ; done
for i in {1..5}; do cat $aFile |sed "s/AVALUE/ci-kube-vv$i/"| kubectl delete -f - ; done
