# Sample ubuntu image you can you for ssh'ing into and testing
# your scripts.
#
FROM ubuntu:16.04

# We need this workaround for ubunbu:16.04 but not for ubuntu:18.04
RUN cp /etc/hosts /tmp/etc_hosts
RUN echo "91.189.88.161 security.ubuntu.com" >> /etc/hosts
RUN apt-get update
RUN apt-get -y install python-pip

# Add some of my favorite untils including kubectl.
#
RUN apt-get install -y vim inetutils-ping git tcpdump psmisc sudo curl net-tools moreutils
RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.10.11/bin/linux/amd64/kubectl
RUN chmod +x ./kubectl
RUN mv ./kubectl /usr/local/bin/kubectl

# Install some version of ansible.
#
RUN pip install ansible\<=2.7.6

# Install openssh.
#
RUN apt-get update && apt-get install -y openssh-server
RUN mkdir /var/run/sshd

RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu
RUN mkdir .ssh

# Fill in the authorized keys with a well know public key so you can
# login via keypair.
#
ADD authorized_keys ./.ssh

USER root
RUN chmod 644 .ssh/authorized_keys

RUN adduser ubuntu sudo
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# SSH login fix. Otherwise user is kicked off after login
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
