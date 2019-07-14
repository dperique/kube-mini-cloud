# Use this script if you don't have a container registry and just
# want to get your image onto your k8s nodes directory.
#
myImage=kube-mc:0.1
docker save $myImage -o /tmp/o.tar
mv /tmp/o.tar .
tar czvf t.tgz ./o.tar 
for i in kube-test-10 ; do
  scp -i junk.rsa t.tgz ubuntu@$i:/tmp
  ssh -i junk.rsa ubuntu@$i  "cd /tmp ; tar xzvf /tmp/t.tgz"
  ssh -i junk.rsa ubuntu@$i  "cd /tmp ; sudo docker load -i o.tar"
done
