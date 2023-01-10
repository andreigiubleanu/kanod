#!/bin/bash

#  Copyright (C) 2020-2023 Orange
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#    The script has been tested on Ubuntu systems, flavors 20.04 and up


set -eu

set -a

NO_KVM_SUPPORT=2
NO_KVM_INSTALL=3
KVM_PERMISSIONS_ISSUES=4
NO_PIP3_INSTALL=5
PYTHON_PACAKGES_PREREQUISITES_ERROR=6
NO_KUBECTL=7
NO_YQ=8


create_log () {
   LOG="${PWD}/create-vmbh-log-$(date +%s).log"
   touch $LOG 
}

kvm_support () {
    KVM_SUPPORT=$(egrep -ci '(vmx|svm)' /proc/cpuinfo)
    if [[ "${KVM_SUPPORT}" -ne 0 ]] 
    then
        echo "KVM support ok." | tee -a "${LOG}"
    else
        echo "KVM support is not enabled. Performance will be impacted." | tee -a "${LOG}"
        echo "Do you still want to continue? Type yes(y) or no(n)?"
        read ANSWER
        case "${ANSWER}" in
        y|YES|yes)
            echo "Script stopped, due to lack of support for KVM." | tee -a "${LOG}"
        ;;
        n|NO|no)
            echo "Script stopped, due to lack of support for KVM." | tee -a "${LOG}"
            exit $NO_KVM_SUPPORT
        ;;
        *)
            echo "Please reply with yes or no, and rerun the script again."
            exit 1
        ;;
       esac       
    fi
}

kvm_install () { 
    if ! dpkg -l | egrep -q -i 'libvirt'
    then
        sudo apt-get update
        sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils libguestfs-tools
        RET=$?
        if [[ "${RET}" -ne 0 ]] 
        then
            echo "Script stopped, not all the tools needed were installed." | tee -a "${LOG}"
            echo "Try to manually install this tools and rerun this script when they are installed." | tee -a "${LOG}"
            exit $NO_KVM_INSTALL
        fi
        sudo adduser `id -un` libvirt
        sudo adduser `id -un` kvm
        # some sanity checking 
        virsh list --all || \
        ( echo "KVM permission issue. Please check https://help.ubuntu.com/community/KVM/installation" | tee -a "${LOG}" && \
          exit $KVM_PERMISSIONS_ISSUES )
    fi
}

kanod_pip3_prerequisites () {
    if ! dpkg -l | egrep -q -i 'python3-pip'
    then
        sudo apt-get update
        sudo apt-get install -y python3-pip
        RET=$?
        if [[ "${RET}" -ne 0 ]] 
        then
            echo "Script stopped.Python pip is not installed." | tee -a "${LOG}"
            echo "Try to manually install python pip package manger and rerun this script when it is installed." | tee -a "${LOG}"
            exit $NO_PIP3_INSTALL
        fi
    fi
}

kanod_python_packages_prerequisites () {
    sudo pip3 install --upgrade pip
    sudo apt-get install -y debootstrap kpartx python3-wheel apache2-utils || \
    (echo "Unable to install some prerequisite utilities. Try to manually install them and rerun the script." | \
    tee -a "${LOG}" && exit $PYTHON_PACAKGES_PREREQUISITES_ERROR)
    sudo pip3 install diskimage-builder || \
    (echo "Unable to install diskimage-builder. Try to manually install the package and rerun the script." | \
    tee -a "${LOG}" && exit $PYTHON_PACAKGES_PREREQUISITES_ERROR)
    pip3 install virtualbmc sushy-tools  --user || \
    (echo "Unable to install virtualbmc and/or sushy-tools. Try to manually install them and rerun the script." | \
    tee -a "${LOG}" && exit $PYTHON_PACAKGES_PREREQUISITES_ERROR)
}

kanod_kubectl_yq_prerequisites ()
{
    if ! which kubectl 
    then
        (curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
        sudo mv ./kubectl /usr/bin/kubectl ) || \
        (echo "Unable to install kubectl. Try to manually install it and rerun the script." | \
        tee -a "${LOG}" && exit $NO_KUBECTL)
    fi
    if ! which yq
    then
        (wget -q  https://github.com/mikefarah/yq/releases/download/v4.30.6/yq_linux_amd64 && sudo mv ./yq_linux_amd64 /usr/local/bin/yq) || \
        (echo "Unable to install yq. Try to manually install it and rerun the script." | tee -a "${LOG}" && exit $NO_YQ)
    fi
}

create_log 
kvm_support
kvm_install
kanod_pip3_prerequisites
kanod_python_packages_prerequisites
kanod_kubectl_yq_prerequisites 