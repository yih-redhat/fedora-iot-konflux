#!/bin/bash
set -euox pipefail

# Dumps details about the instance running the CI job.
CPUS=$(nproc)
MEM=$(free -m | grep -oP '\d+' | head -n 1)
DISK=$(df --output=size -h / | sed '1d;s/[^0-9]//g')
HOSTNAME=$(uname -n)
USER=$(whoami)
ARCH=$(uname -m)
KERNEL=$(uname -r)

echo -e "\033[0;36m"
cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
     Hostname: ${HOSTNAME}
         User: ${USER}
         CPUs: ${CPUS}
          RAM: ${MEM} MB
         DISK: ${DISK} GB
         ARCH: ${ARCH}
       KERNEL: ${KERNEL}
------------------------------------------------------------------------------
EOF
echo "CPU info"
lscpu
echo -e "\033[0m"

# Get OS data.
source /etc/os-release

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# set locale to en_US.UTF-8
sudo dnf install -y glibc-langpack-en
sudo localectl set-locale LANG=en_US.UTF-8

# Install required packages
greenprint "Install required packages"
sudo dnf install -y --nogpgcheck httpd podman skopeo wget firewalld lorax xorriso curl jq expect qemu-img qemu-kvm libvirt-client libvirt-daemon-kvm libvirt-daemon virt-install rpmdevtools createrepo_c

# Customize repository
sudo mkdir -p /etc/osbuild-composer/repositories

# Check ostree_key permissions
KEY_PERMISSION_PRE=$(stat -L -c "%a %G %U" key/ostree_key | grep -oP '\d+' | head -n 1)
echo -e "${KEY_PERMISSION_PRE}"
if [[ "${KEY_PERMISSION_PRE}" != "600" ]]; then
   greenprint "💡 File permissions too open...Changing to 600"
   chmod 600 ./key/ostree_key
fi

# Start httpd server as prod ostree repo
greenprint "Start httpd service"
sudo systemctl enable --now httpd.service

# Start firewalld
greenprint "Start firewalld"
sudo systemctl enable --now firewalld

# Allow anyone in the wheel group to talk to libvirt.
greenprint "🚪 Allowing users in wheel group to talk to libvirt"
sudo tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("adm")) {
            return polkit.Result.YES;
    }
});
EOF

# Start libvirtd and test it.
greenprint "🚀 Starting libvirt daemon"
sudo systemctl start libvirtd
sudo virsh list --all > /dev/null

# Set a customized dnsmasq configuration for libvirt so we always get the
# same address on boot-up.
greenprint "💡 Setup libvirt network"
sudo tee /tmp/integration.xml > /dev/null << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>integration</name>
  <uuid>1c8fe98c-b53a-4ca4-bbdb-deb0f26b3579</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='integration' zone='trusted' stp='on' delay='0'/>
  <mac address='52:54:00:36:46:ef'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <host mac='34:49:22:B0:83:30' name='vm-1' ip='192.168.100.50'/>
      <host mac='34:49:22:B0:83:31' name='vm-2' ip='192.168.100.51'/>
      <host mac='34:49:22:B0:83:32' name='vm-3' ip='192.168.100.52'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='dhcp-vendorclass=set:efi-http,HTTPClient:Arch:00016'/>
    <dnsmasq:option value='dhcp-option-force=tag:efi-http,60,HTTPClient'/>
    <dnsmasq:option value='dhcp-boot=tag:efi-http,&quot;http://192.168.100.1/httpboot/EFI/BOOT/BOOTX64.EFI&quot;'/>
  </dnsmasq:options>
</network>
EOF
if ! sudo virsh net-info integration > /dev/null 2>&1; then
    sudo virsh net-define /tmp/integration.xml
fi
if [[ $(sudo virsh net-info integration | grep 'Active' | awk '{print $2}') == 'no' ]]; then
    sudo virsh net-start integration
fi

# In case port 8081 is already in use
sudo dnf install -y lsof
if lsof -nP -iTCP -sTCP:LISTEN|grep 8081; then
    sudo fuser -k 8081/tcp
fi

# Install FDO packages (This cannot be done in the setup.sh because FDO packages are not available on fedora)
sudo dnf install -y \
    fdo-admin-cli \
    fdo-rendezvous-server \
    fdo-owner-onboarding-server \
    fdo-owner-cli \
    fdo-manufacturing-server \
    python3-pip

# Generate key and cert used by FDO
sudo mkdir -p /etc/fdo/keys
for obj in diun manufacturer device-ca owner; do
    sudo fdo-admin-tool generate-key-and-cert --destination-dir /etc/fdo/keys "$obj"
done

# Copy configuration files
sudo mkdir -p \
    /etc/fdo/manufacturing-server.conf.d/ \
    /etc/fdo/owner-onboarding-server.conf.d/ \
    /etc/fdo/rendezvous-server.conf.d/ \
    /etc/fdo/serviceinfo-api-server.conf.d/

sudo cp files/manufacturing-server.yml /etc/fdo/manufacturing-server.conf.d/
sudo cp files/owner-onboarding-server.yml /etc/fdo/owner-onboarding-server.conf.d/
sudo cp files/rendezvous-server.yml /etc/fdo/rendezvous-server.conf.d/
sudo cp files/serviceinfo-api-server.yml /etc/fdo/serviceinfo-api-server.conf.d/

# Install yq to modify service api server config yaml file
sudo pip3 install yq
# Prepare service api server config file
sudo /usr/local/bin/yq -iy '.service_info.diskencryption_clevis |= [{disk_label: "/dev/vda3", reencrypt: true, binding: {pin: "tpm2", config: "{}"}}]' /etc/fdo/serviceinfo-api-server.conf.d/serviceinfo-api-server.yml
# Start FDO services
sudo systemctl start \
    fdo-owner-onboarding-server.service \
    fdo-rendezvous-server.service \
    fdo-manufacturing-server.service \
    fdo-serviceinfo-api-server.service

# Wait for fdo server to be running
until [ "$(curl -X POST http://192.168.100.1:8080/ping)" == "pong" ]; do
    sleep 1;
done;

exit 0
