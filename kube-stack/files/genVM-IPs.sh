# Assume all pods in k8s-test and zuul-ci are VMs.
#
echo "" > ssh_config2
for NAMESPACE in k8s-test zuul-ci; do

  for name in $(kubectl get vmi -n $NAMESPACE -o=custom-columns=NAME:.metadata.name --no-headers); do

    theIP=$(kubectl get vmi $name -n $NAMESPACE --output='jsonpath={.status.interfaces[0].ipAddress}')
    theName=$(echo $name | sed 's/^vmi-//')
    echo "" >> ssh_config2
    echo "Host $theName" >> ssh_config2
    echo "  User bonnyci" >> ssh_config2
    echo "  HostName $theIP" >> ssh_config2
    echo "  StrictHostKeyChecking no" >> ssh_config2
    echo "  ProxyCommand ssh -A -W %h:%p kube-stack-4" >> ssh_config2
    echo "  IdentityFile ~/.ssh/junk.id_rsa" >> ssh_config2

  done

done
