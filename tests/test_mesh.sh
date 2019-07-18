# Pick a pod name that will be on every node (like a daemonset name).
#
aPodName="$aPodName"

# Do a full mesh ping to ensure every pod can ping every pod.
#
for i in $(kubectl get po -o wide | grep $aPodName | awk '{print $6}'); do

  for j in $(kubectl get po | grep $aPodName | awk '{print $1}'); do

    # All pings should succeed.  Look for hanging pings
    #
    kubectl exec $j -- ping -c 2 -i .1 $i

  done

done
