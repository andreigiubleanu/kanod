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
#
#    The script has been tested on Ubuntu systems, flavors 20.04 and up.
#    The  purpose of the script is to simulate remote management for virtual 
#    machines ,thus treating them like bare metal hosts. In real life, you can 
#    always access servers by using protocols such as IPMI, by interacting 
#    with the baseboard management controller. In consequence, the script creates
#    a controlled number of vms started in BIOS mode, and shuts them down.  
#    By default, we simulate a BMC on each emulated server with python virtual BMC and IPMI. 
#    The shell script creates a complete configuration for the vbmc daemon and launches it.
#    The ports used start at 5001. We can list the declared BMC and their characteristics
#    as follows(export the VIRTUALBMC_CONFIG variable and list the bmcs with the vbmc command):
#    export VIRTUALBMC_CONFIG=<<path-to-your>>virtualbmc.conf    
#    vbmc list
#    +-------------+---------+---------+------+
#    | Domain name | Status  | Address | Port |
#    +-------------+---------+---------+------+
#    | vmok-1      | running | ::      | 5001 |
#    | vmok-2      | running | ::      | 5002 |
#    | vmok-3      | running | ::      | 5003 |
#    +-------------+---------+---------+------+
#
#    The script is done by reworking some assets from the Kanod and Kanod in
#    a bottle projects. Kudos goes to all contributors of these projects.
#    Please check the following links:
#    https://gitlab.com/Orange-OpenSource/kanod/
#    https://gitlab.com/Orange-OpenSource/kanod/kanod-in-a-bottle


set -e

set -a

###############
# PREREQUISITES
###############

# exit codes
NO_KVM_SUPPORT=2
NO_KVM_INSTALL=3
KVM_PERMISSIONS_ISSUES=4
NO_PIP3_INSTALL=5
PYTHON_PACAKGES_PREREQUISITES_ERROR=6
NO_KUBECTL=7
NO_YQ=8
NO_BMC_PROTOCOL=9
UNSUPPORTED_OS=10
UNSUPPORTED_UBUNTU_VERSION=11
NO_APACHE2_UTILS=12

create_log () {
   LOG="${PWD}/create-vmbh-prereq-log-$(date +%s).log"
   touch $LOG 
}

fail_fast () {
    if ! egrep -q ubuntu /etc/os-release
    then 
        echo -e "Unsupported operating system.\n
        Make sure you are running Ubuntu as your distro."  | tee -a "${LOG}" && exit "${UNSUPPORTED_OS}"
    else
        declare -a SUPPORTED_OS=(20.04 22.04)
        OS_VERSION=$(cat /etc/os-release | awk -F"\"" '{print $1,$2}' | egrep VERSION_ID | awk -F " " '{print $2}')
        if ! echo ${SUPPORTED_OS[@]} | grep -q -F "${OS_VERSION}"
        then
             echo -e "Make sure you are running the long time release branches for Ubuntu,\n
                      so that you don't have trouble fetching the prerequisites.\n
                      Accepted versions are: 20.04 and 22.04"  | tee -a "${LOG}"  && exit "${UNSUPPORTED_UBUNTU_VERSION}"
        fi
    fi
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

pip3_prerequisites () {
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

python_packages_prerequisites () {
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

kubectl_yq_apache2-utils_prerequisites ()
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
    if ! which htpasswd 
    then
        sudo apt install apache2-utils ||\
        echo "Unable to install apache2-utils. Try to manually install it and rerun the script." | tee -a "${LOG}" && exit $NO_APACHE2_UTILS
    fi 
}

###############
# VIRSH DOMAINS
###############

# The following variables control the behaviour for the creation of domains, networks and storage
# You can experiment with different settings for your infrastructure

TPM=0
AIRGAP=0
NB_VM=3
DISK_SIZE='10G'
STORAGE_POOL='okstore'
MEMORY=7000
VCPU=2
NETWORK='oknet'
BRIDGE_NAME='virbr1'
IP_ADDRESS='192.168.133.1'
BMC_HOST='192.168.133.1'

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
    if ! virsh pool-list --inactive  | tail -n +3 | grep -q "$STORAGE_POOL"
    then
        for volume in $(virsh vol-list "${STORAGE_POOL}" | awk '{print $1}' | grep "^${vol}-[0-9]*$"); do
            echo "- Delete volume ${vol}"
            virsh vol-delete "${volume}" "${STORAGE_POOL}"
        done
    fi
}

# Domain, network and storage creation

create_network ()
{
     if [[ $(virsh net-list | tail +3 | awk '{print $1}') =~ (^|[[:space:]])"${NETWORK}"($|[[:space:]]) ]]; then
        echo 'Network already exists'
     else
        virsh net-define /dev/stdin <<EOF
<network>
<name>${NETWORK}</name>
<forward mode='nat'/>
<bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
<ip address='${IP_ADDRESS}' netmask='255.255.255.0'>
</ip>
</network>
EOF
        virsh net-start "${NETWORK}"
        virsh net-autostart "${BRIDGE_NAME}" 
    fi   
}

create_storage () {
    if ! [[ "$(virsh pool-list --name)" =~ "${STORAGE_POOL}" ]]; then
        virsh pool-define-as --type dir --name "${STORAGE_POOL}" --target "/home/$(whoami)/${STORAGE_POOL}"
        virsh pool-start "${STORAGE_POOL}"
        virsh pool-autostart "${STORAGE_POOL}"
    fi
}

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
# You can choose between ipmi or redfish protocols

BMC_PROTOCOL="ipmi"
BMC_PASSWORD="orange123."
LAB_DIR=""

create_bmc () {

    [ -z $LAB_DIR ] && echo "Please specify the path for your lab directory creation: " && read LAB_DIR

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
        vbmcd # don't know what this is

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
        # In order to run vbmc commands you need to export VIRTUALBMC_CONFIG=${LAB_DIR}/vbmc/virtualbmc.conf 
        # Afterwards you can run for example vbmc list

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
        echo "Unknown protocol for bmc : ${BMC_PROTOCOL}"
        exit "$NO_BMC_PROTOCOL"
    fi
}

# MAIN
create_log 
fail_fast
# prerequisites install
kvm_support
kvm_install
pip3_prerequisites
python_packages_prerequisites
kubectl_yq_apache2-utils_prerequisites
# cleanup
domain_destroy
domain_undefine
vol_delete
# objects creation
create_network
create_storage
create_domain
create_bmc
