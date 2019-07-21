#!/bin/bash

if [[ "$3" == "" ]]; then
  echo ""
  echo "  Usage: $0 <anAction> <aName> <anImage>"
  echo ""
  echo "  anAction:"
  echo "    create: create the container"
  echo "    delete: delete the container"
  echo ""
  echo "  Images:"
  echo "    localhost:5000/kube-stack/kuul_zuul_periodics:v2.8b-ssh"
  echo ""
  exit 1
fi

anAction=$1
aName=$2
anImage=$3
NAMESPACE=kuul-pods
CONTEXT=kube-stack

if [[ $anImage == "default" ]]; then
  anImage="localhost:5000/kube-stack/kuul_zuul_periodics:v2.8b-ssh"
fi
if [[ "$anAction" == "create" ]]; then
  cat pod-template.yaml | sed -e "s/SOMENAME/$aName/g" -e "s,SOMEIMAGE,$anImage,g" | kubectl apply --context $CONTEXT -f -

else
  cat pod-template.yaml | sed -e "s/SOMENAME/$aName/g" -e "s,SOMEIMAGE,$anImage,g" | kubectl delete --context $CONTEXT -f -
fi

echo ""
echo "# This is a generated file" > ssh_config

echo "# We will ssh to Pods via node 4 use your particular IP"
echo "Host kube-stack-4" >> ssh_config
echo "  HostName 10.171.203.72" >> ssh_config
echo "  User ubuntu" >> ssh_config
echo "  IdentityFile ~/.ssh/kube-stack.rsa" >> ssh_config
echo "" >> ssh_config

for i in $(kubectl -n $NAMESPACE --context $CONTEXT get svc --no-headers | awk '{print $1}'); do

  theIP=$(kubectl -n $NAMESPACE --context $CONTEXT get svc $i -o jsonpath="{.spec.clusterIP}")
  echo "" >> ssh_config
  echo "Host $i" >> ssh_config
  echo "  User bonnyci" >> ssh_config
  echo "  HostName $theIP" >> ssh_config
  echo "  StrictHostKeyChecking no" >> ssh_config
  echo "  ProxyCommand ssh -A -W %h:%p kube-stack-4" >> ssh_config
  echo "  IdentityFile ~/.ssh/junk.id_rsa" >> ssh_config

  printf "%15s   %-15s\n" $i $theIP

done

thePwd=`pwd`
echo ""
echo "alias sshp=\"ssh -F $thePwd/ssh_config\""
echo ""
