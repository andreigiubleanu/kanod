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

###############
# PREREQUISITES
###############


NO_KVM_SUPPORT=2
NO_KVM_INSTALL=3
KVM_PERMISSIONS_ISSUES=4
NO_PIP3_INSTALL=5
PYTHON_PACAKGES_PREREQUISITES_ERROR=6
NO_KUBECTL=7
NO_YQ=8
NO_BMC_PROTOCOL=9

create_log () {
   LOG="${PWD}/create-vmbh-prereq-log-$(date +%s).log"
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


###############
# VIRSH DOMAINS
###############

# Domains and vols cleanup

domain_destroy () {
    vm=$(echo ${1:-vmok})
    echo "Domain clean-up"
    for domain in $(virsh list --name --state-running | grep "^${vm}-[0-9]*$") ; do
        echo "- Delete domain ${domain}"
        virsh destroy "${domain}"
    done
}

domain_undefine () {
    vm=$(echo ${1:-vmok})
    for domain in $(virsh list --name --all | grep "^${vm}-[0-9]*$"); do
        echo "- Undefine domain ${domain}"
        virsh undefine "${domain}"
    done
}

vol_delete () {
    STORAGE_POOL=$(echo ${1:-okstore})
    vol=$(echo ${2:-vol})
    for volume in $(virsh vol-list "${STORAGE_POOL}" | awk '{print $1}' | grep "^${vol}-[0-9]*$"); do
        echo "- Delete volume ${vol}"
        virsh vol-delete "${volume}" "${STORAGE_POOL}"
    done
}

# Domain creation
# The following variables control the behaviour of the create_domain function
# You can experiment with different settings for your infrastructure

TPM=0
AIRGAP=0
NB_VM=3
DISK_SIZE='10G'
STORAGE_POOL='okstore' # if it doesn't exist, needs to be manually created before running this script
MEMORY=7000
VCPU=2
NETWORK='oknet' # if it doesn't exist, needs to be manually created before running this script

create_domain ()
{
    declare -a tpm
    if [ "$TPM" == 1 ]; then
        tpm=(--tpm 'backend.type=emulator,backend.version=2.0,model=tpm-tis')
    fi

    if [ "$AIRGAP" == 1 ]; then
        airgap=',filterref.filter=kanod-airgap-mode'
    else
        airgap=''
    fi

    echo "VM Creation"
    for ((i=1;i<=NB_VM;i++)); do
        vol="vol-$i"
        mac=$(printf "52:54:00:01:00:%02d" "${i}")
        domain="vmok-$i"

        echo "- Create volume ${vol} (size: ${DISK_SIZE:-10G})"
        virsh vol-create-as "${STORAGE_POOL:-okstore}" "$vol" "${DISK_SIZE:-10G}" --format raw

        echo "- Create domain ${domain}"
        virt-install --name "$domain" --memory "${MEMORY:-7000}" --vcpu "${VCPU:-2}"  \
            --cpu host-passthrough --os-variant generic \
            --disk "device=disk,vol=${STORAGE_POOL:-okstore}/${vol},bus=virtio,format=raw" \
            --pxe --noautoconsole \
            --network "network=${NETWORK:-oknet},model=virtio,mac=${mac}${airgap}" \
            "${tpm[@]}"
    done

    sleep 10

    for ((i=1;i<=NB_VM;i++)); do
        echo "Stop domain ${vmok-$i}"
        virsh destroy "vmok-$i"
    done
}


#############
# Virtual BMC
#############

# Virtual BMC creation
# The following variables control the behaviour of the create_bmc function

BMC_PROTOCOL=""
BMC_PASSWORD=""
create_bmc () {

    if ! which htpasswd 
    then
        sudo apt install apache2-utils || true
    fi 

    [ -z $LABDIR ] && echo "Please specify the path for your lab directory creation: " && read LABDIR

    if [ "${BMC_PROTOCOL}" = "ipmi" ]; then
    vbmc_config="${LAB_DIR}/vbmc"

    if [ -f "${vbmc_config}/vbmc.pid" ]; then
        pid="$(cat "${vbmc_config}/vbmc.pid")"
        if [ "$pid" != '0' ]; then
        echo "Killing $pid"
        kill -9 "$pid" || true
        rm "${vbmc_config}/vbmc.pid"
        fi
    fi

    rm -rf "$vbmc_config"
    mkdir -p "$vbmc_config"
    cat > "$vbmc_config/virtualbmc.conf" <<EOF
    [default]
    config_dir: ${vbmc_config}
    pid_file: ${vbmc_config}/vbmc.pid
    server_port: 51000
    [log]
    logfile: ${vbmc_config}/log.txt
EOF

    echo 'Launching vbmc'
    # Why vbmc is using pyperclip ?
    export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"
    export VIRTUALBMC_CONFIG="$vbmc_config/virtualbmc.conf"
    # vbmcd # don't know what this is

    while ! vbmc list &> /dev/null; do
        echo -n .
        sleep 1
    done

    for ((i=1;i<=NB_VM;i++)) do
        port=$((5000+i))
        domain="vmok-$i"
        vbmc add --username root --password "${BMC_PASSWORD}" --port "${port}" "${domain}"
        vbmc start "${domain}"
    done

    elif [ "${BMC_PROTOCOL}" = "redfish" ] || [ "${BMC_PROTOCOL}" = "redfish-virtualmedia" ]; then
    echo 'Launching Virtual Redfish BMC'

    vbmcredfish_config="${LAB_DIR}/vbmcredfish"

    for ((i=1;i<=NB_VM;i++)); do
        if [ -f "${vbmcredfish_config}/vbmcredfish-${i}.pid" ]; then
        pid="$(cat "${vbmcredfish_config}/vbmcredfish-${i}.pid")"
        if [ "$pid" != '0' ]; then
            echo "Stopping sushy-emulator with pid ${pid}"
            kill -9 "$pid" >& /dev/null || true
            rm -f "${vbmcredfish_config}/vbmcredfish-${i}.pid"
        fi
        fi
    done

    set +e
    pidlist=$(mktemp)
    pgrep -a sushy-emulator  > "${pidlist}"
    if [ -s "${pidlist}" ]; then
        echo "!!! WARNING !!!"
        echo "   Remaining sushy-emulator processus:"
        cat "${pidlist}"
    fi
    rm "${pidlist}"
    set -e

    rm -rf "${vbmcredfish_config}"
    mkdir -p "$vbmcredfish_config"

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout  "${vbmcredfish_config}"/key.pem \
        -out "${vbmcredfish_config}"/cert.pem \
        -addext "subjectAltName = IP:${BMC_HOST}" \
        -subj "/C=--/L=-/O=-/CN=${BMC_HOST}" &> /dev/null

    for ((i=1;i<=NB_VM;i++)); do
        port=$((5000+i))
        vmName="vmok-$i"
        allowedInstances=$(virsh list --all --name  --uuid | awk -v name=${vmName} '$2==name {print $2 "," $1}')
        cat > "$vbmcredfish_config/emulator-${i}.conf" <<EOF
    SUSHY_EMULATOR_LISTEN_IP = "${BMC_HOST}"
    SUSHY_EMULATOR_LISTEN_PORT = "${port}"
    SUSHY_EMULATOR_SSL_CERT = "${vbmcredfish_config}/cert.pem"
    SUSHY_EMULATOR_SSL_KEY = "${vbmcredfish_config}/key.pem"
    SUSHY_EMULATOR_AUTH_FILE = "${vbmcredfish_config}/htpasswd-${i}.txt"
    SUSHY_EMULATOR_LIBVIRT_URI = u"qemu:///system"
    SUSHY_EMULATOR_ALLOWED_INSTANCES = "${allowedInstances}"
EOF

        htpasswd -cbB "$vbmcredfish_config"/htpasswd-"${i}".txt root "${BMC_PASSWORD}" &> /dev/null

        echo "Launching virtual redfish bmc on ${BMC_HOST}:${port} for ${vmName}"
        SUSHY_EMULATOR_CONFIG="${ROOT_DIR}/redfish/sushy_extension.py" sushy-emulator --config "${vbmcredfish_config}"/emulator-"${i}".conf &> "${vbmcredfish_config}"/sushy-"${i}".log &

        # shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
            echo $! > "${vbmcredfish_config}/vbmcredfish-${i}.pid";
        else
            echo "Error during sushy-emulator launch"
            exit 1
        fi
    done
    else
        echo "unknown protocol for bmc : ${BMC_PROTOCOL}"
        exit "$NO_BMC_PROTOCOL"
    fi
}


#create_log 
# prerequisites install
#kvm_support
#kvm_install
#kanod_pip3_prerequisites
#kanod_python_packages_prerequisites
#kanod_kubectl_yq_prerequisites
#domain_destroy
#domain_undefine
#vol_delete
#create_domain
