#!/bin/bash

# This outputs to stdout an ansible inventory file for matched list of
# VMs so you can make a Kubernetes cluster using kubespray.
# This is pretty standard except we like to put a database on nodes 1,2,3
# and Prometheus on nodes 4,5.  Having those variables there is harmless
# and you don't have to use them.
#
# Argument one is the name of the Kubernetes cluster.
# Argument two is the namespace to search for the names.
#
# Create the five VMs first using the Kubernetes name and this will extract
# the IP addresses and then create an inventory for use with kubespray.
#
if [[ "$2" == "" ]]; then
  echo ""
  echo "  Usage: $0 <name of kube cluster> <namespace where the VMs reside>"
  echo ""
  echo "  Outputs an kubespray ansible inventory file."
  echo ""
  exit 1
fi

KUBE_NAME=$1
NAMESPACE=$2
let count=1

for anIP in $(kubectl -n $NAMESPACE get vmi|grep $KUBE_NAME|awk '{print $4}'); do
  if [[ "$count" == "4" ]]; then
    echo "${KUBE_NAME}-k8s-node-${count} ansible_host=${anIP} ip=${anIP} ansible_user=ubuntu database_node_ord=${count} prometheus_node_ord=4"
    let count=$count+1
    continue
  fi
  if [[ "$count" == "5" ]]; then
    echo "${KUBE_NAME}-k8s-node-${count} ansible_host=${anIP} ip=${anIP} ansible_user=ubuntu database_node_ord=${count} prometheus_node_ord=5"
    let count=$count+1
    continue
  fi
  echo "${KUBE_NAME}-k8s-node-${count} ansible_host=${anIP} ip=${anIP} ansible_user=ubuntu database_node_ord=${count}"
  let count=$count+1
done

cat inventory-template.yaml | sed "s/KUBE_NAME/$KUBE_NAME/g"
