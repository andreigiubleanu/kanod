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

create_log () {
   LOG="${PWD}/create-vmbh-log-$(date +%s).log"
   touch $LOG 
}

kvm_support () {
    KVM_SUPPORT=$(egrep -ci '(vmx|svm)' /proc/cpuinfo)
    if [[ "${KVM_SUPPORT}" -ne 0 ]] 
    then
        echo "KVM support ok." | tee -a $LOG
    else
        echo "KVM support is not enabled. Performance will be impacted." | tee -a $LOG
        echo "Do you still want to continue? Type yes(y) or no(n)?"
        read ANSWER
        case "${ANSWER}" in
        y|YES|yes)
            echo "Script stopped, due to lack of support for KVM." | tee -a $LOG
        ;;
        n|NO|no)
            echo "Script stopped, due to lack of support for KVM." | tee -a $LOG
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
        sudo apt-get upgrade
        sudo apt-get install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils libguestfs-tools
        RET=$?
        if [[ "${RET}" -ne 0 ]] 
        then
            echo "Script stopped, not all the tools needed were installed." | tee -a $LOG
            echo "Try to manually install this tools and rerun this script when they are installed." | tee -a $LOG
            exit $NO_KVM_INSTALL
        fi
        sudo adduser `id -un` libvirt
        sudo adduser `id -un` kvm
        # some sanity checking 
        virsh list --all || \
        ( echo "KVM permission issue. Please check https://help.ubuntu.com/community/KVM/installation" | tee -a $LOG && \
          exit $KVM_PERMISSIONS_ISSUES )
    fi
}

create_log 
kvm_support
kvm_install
