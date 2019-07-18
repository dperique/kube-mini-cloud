# This creates an ansible inventory file or a five node Kubernetes cluster.
# This is pretty standard except we like to put a database on nodes 1,2,3
# and Prometheus on nodes 4,5.  Having those variables there is harmless
# and you don't have to use them.
#
# Argument one is the name of the Kubernetes cluster.
#
# Produces an output file call $A_FILE (inventory99.yaml).
# Create the five VMs first using the Kubernetes name and this will extract
# the IP addresses and then create an inventory for use with kubespray.
#
KUBE_NAME=$1
A_FILE=inventory99.yaml
let count=1
echo > $A_FILE
for anIP in $(kubectl -n kubevirt get vmi|grep ci-kube2|awk '{print $4}'); do
  if [[ "$count" == "4" ]]; then
    echo "${KUBE_NAME}-k8s-node-${count} ansible_host=${anIP} ip=${anIP} ansible_user=ubuntu database_node_ord=${count} prometheus_node_ord=4" >> $A_FILE
    let count=$count+1
    continue
  fi
  if [[ "$count" == "5" ]]; then
    echo "${KUBE_NAME}-k8s-node-${count} ansible_host=${anIP} ip=${anIP} ansible_user=ubuntu database_node_ord=${count} prometheus_node_ord=5" >> $A_FILE
    let count=$count+1
    continue
  fi
  echo "${KUBE_NAME}-k8s-node-${count} ansible_host=${anIP} ip=${anIP} ansible_user=ubuntu database_node_ord=${count}" >> $A_FILE
  let count=$count+1
done

cat inventory-template.yaml | sed "s/KUBE_NAME/$KUBE_NAME/g" >> $A_FILE
