#!/bin/bash

# ==============================================================================
# DECLARATIVE VM MAPPER (Define your VMs here)
# Format: "VM_NAME | IP_ADDRESS | RAM_MB | VCPUS"
# ==============================================================================
VM_LIST=(
  "ubuntu-kvm-1 | 192.168.122.11 | 1024 | 1"
  "ubuntu-kvm-2 | 192.168.122.12 | 1024 | 1"
)

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================
VM_USER="ubuntu"
VM_PASS="ubuntu"
VM_CIDR="24"
VM_GATEWAY="192.168.122.1"
VM_DNS="8.8.8.8"
VM_DISK_SIZE="10G"

IMG_DIR="/var/lib/libvirt/images"
BASE_IMG="ubuntu-22.04-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or using sudo."
  exit 1
fi

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep -w $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

echo "=========================================================="
echo " IDEMPOTENT KVM SETUP: DECLARATIVE MULTI-VM PROVISIONING  "
echo "=========================================================="

# ==============================================================================
# PHASE 1: IDEMPOTENCY CHECKS
# ==============================================================================
echo "[1/5] Running idempotency checks..."

NEEDS_PURGE=false
if command -v kubeadm &> /dev/null || dpkg -l | grep -q "xfce4" || command -v containerd &> /dev/null; then
    NEEDS_PURGE=true
    echo "      [-] Legacy components found. Scheduled for purge."
else
    echo "      [+] System already clean. Skipping purge."
fi

NEEDS_INSTALL=false
if ! command -v virsh &> /dev/null || ! command -v cloud-localds &> /dev/null || ! command -v sshpass &> /dev/null; then
    NEEDS_INSTALL=true
    echo "      [-] Missing KVM dependencies. Scheduled for installation."
else
    echo "      [+] KVM dependencies already installed. Skipping installation."
fi

# ==============================================================================
# PHASE 2: BACKGROUND TASKS (If needed)
# ==============================================================================
if [ "$NEEDS_PURGE" = true ] || [ "$NEEDS_INSTALL" = true ]; then
    echo "[2/5] Running system updates in the background..."
    (
        if [ "$NEEDS_PURGE" = true ]; then
            kubeadm reset -f >/dev/null 2>&1 || true
            rm -rf ~/.kube /etc/kubernetes/ /var/lib/kubelet/ /var/lib/etcd/ /var/lib/cni/ /etc/cni/net.d/
            systemctl stop containerd docker >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get purge -y kubeadm kubectl kubelet kubernetes-cni kube* containerd containerd.io docker-ce docker-ce-cli docker-ce-rootless-extras runc xfce4 xfce4-goodies tigervnc-standalone-server novnc websockify firefox >/dev/null 2>&1
            iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1
        fi

        if [ "$NEEDS_INSTALL" = true ]; then
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst cloud-image-utils sshpass >/dev/null 2>&1
            systemctl enable --now libvirtd >/dev/null 2>&1
        fi
    ) &
    BG_PID=$!
else
    echo "[2/5] No system updates required. Skipping."
    BG_PID=""
fi

# ==============================================================================
# PHASE 3: FETCH BASE IMAGE
# ==============================================================================
echo "[3/5] Checking Ubuntu 22.04 Cloud Image..."
mkdir -p $IMG_DIR
if [ ! -f "$IMG_DIR/$BASE_IMG" ]; then
    echo "      Downloading image..."
    wget -q --show-progress -O $IMG_DIR/$BASE_IMG $IMG_URL
else
    echo "      [+] Image already exists locally. Skipping download."
fi

# Wait for background APT tasks if they are running
if [ -n "$BG_PID" ]; then
    echo -n "      Waiting for background system tasks to finish... "
    spinner $BG_PID
    echo "[Done]"
fi

# Ensure libvirtd is active before proceeding
systemctl start libvirtd >/dev/null 2>&1

# ==============================================================================
# PHASE 4: DECLARATIVE VM PROVISIONING
# ==============================================================================
echo "[4/5] Provisioning VMs from Mapper..."
mkdir -p /tmp/cloudinit

for vm_data in "${VM_LIST[@]}"; do
    # Parse the mapper string
    IFS='|' read -r RAW_NAME RAW_IP RAW_RAM RAW_VCPUS <<< "$vm_data"
    VM_NAME=$(trim "$RAW_NAME")
    VM_IP=$(trim "$RAW_IP")
    VM_RAM=$(trim "$RAW_RAM")
    VM_VCPUS=$(trim "$RAW_VCPUS")

    echo "      -> Evaluating VM: $VM_NAME ($VM_IP)"

    # Idempotency Check: Does VM exist?
    if virsh dominfo "$VM_NAME" > /dev/null 2>&1; then
        echo "         [+] VM '$VM_NAME' already exists."
        
        # Check if it's running
        if virsh domstate "$VM_NAME" | grep -q "shut off"; then
            echo -n "         [-] VM is stopped. Starting it now... "
            virsh start "$VM_NAME" > /dev/null 2>&1
            echo "[Done]"
        else
            echo "         [+] VM is currently running."
        fi
        continue # Skip creation
    fi

    # If not exists, Create VM
    echo -n "         [-] Creating $VM_NAME... "
    
    # 1. Setup virtual disk (Linked clone)
    qemu-img create -f qcow2 -F qcow2 -b $IMG_DIR/$BASE_IMG $IMG_DIR/${VM_NAME}.qcow2 $VM_DISK_SIZE > /dev/null 2>&1

    # 2. User-data
    cat <<EOF > /tmp/cloudinit/user-data-${VM_NAME}
#cloud-config
password: $VM_PASS
chpasswd: { expire: False }
ssh_pwauth: True
runcmd:
  - sed -i -e '/^PasswordAuthentication/s/^.*$/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
EOF

    # 3. Meta-data
    cat <<EOF > /tmp/cloudinit/meta-data-${VM_NAME}
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    # 4. Network-config
    cat <<EOF > /tmp/cloudinit/network-config-${VM_NAME}
network:
  version: 2
  ethernets:
    nic0:
      match:
        name: en*
      dhcp4: false
      addresses:
        - $VM_IP/$VM_CIDR
      routes:
        - to: default
          via: $VM_GATEWAY
      nameservers:
        addresses:
          - $VM_DNS
EOF

    # 5. Compile Cloud-Init ISO
    cloud-localds --network-config=/tmp/cloudinit/network-config-${VM_NAME} $IMG_DIR/${VM_NAME}-seed.iso /tmp/cloudinit/user-data-${VM_NAME} /tmp/cloudinit/meta-data-${VM_NAME} > /dev/null 2>&1

    # 6. Install VM
    virt-install \
        --name $VM_NAME \
        --ram $VM_RAM \
        --vcpus $VM_VCPUS \
        --disk path=$IMG_DIR/${VM_NAME}.qcow2,format=qcow2 \
        --disk path=$IMG_DIR/${VM_NAME}-seed.iso,device=cdrom \
        --os-variant ubuntu22.04 \
        --network network=default \
        --import \
        --noautoconsole > /dev/null 2>&1
    
    echo "[Created]"
done

# ==============================================================================
# PHASE 5: HEALTH CHECKS
# ==============================================================================
echo "[5/5] Performing Health Checks via SSH..."
spinstr='|/-\'

for vm_data in "${VM_LIST[@]}"; do
    IFS='|' read -r RAW_NAME RAW_IP RAW_RAM RAW_VCPUS <<< "$vm_data"
    VM_NAME=$(trim "$RAW_NAME")
    VM_IP=$(trim "$RAW_IP")

    echo -n "      Checking $VM_NAME ($VM_IP)... "
    MAX_RETRIES=300
    COUNT=0
    VM_READY=false

    while [ $COUNT -lt $MAX_RETRIES ]; do
        if sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 $VM_USER@$VM_IP "hostname" > /dev/null 2>&1; then
            VM_READY=true
            break
        fi
        
        temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 2
        printf "\b\b\b\b\b\b"
        
        COUNT=$((COUNT+1))
    done
    printf "      \b\b\b\b\b\b"

    if [ "$VM_READY" = true ]; then
        echo "[OK]"
    else
        echo "[TIMEOUT - Check manually: virsh console $VM_NAME]"
    fi
done

echo -e "\n=========================================================="
echo "                 SETUP COMPLETED SUCCESSFULLY               "
echo "=========================================================="
printf "%-15s | %-15s | %-6s | %-5s\n" "VM NAME" "IP ADDRESS" "RAM" "vCPU"
echo "----------------------------------------------------------"
for vm_data in "${VM_LIST[@]}"; do
    IFS='|' read -r RAW_NAME RAW_IP RAW_RAM RAW_VCPUS <<< "$vm_data"
    VM_NAME=$(trim "$RAW_NAME")
    VM_IP=$(trim "$RAW_IP")
    VM_RAM=$(trim "$RAW_RAM")
    VM_VCPUS=$(trim "$RAW_VCPUS")
    printf "%-15s | %-15s | %-6s | %-5s\n" "$VM_NAME" "$VM_IP" "${VM_RAM}MB" "$VM_VCPUS"
done
echo "=========================================================="
echo "Default Login: ssh $VM_USER@<IP> (Password: $VM_PASS)"
