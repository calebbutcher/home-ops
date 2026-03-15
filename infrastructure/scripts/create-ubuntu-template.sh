#!/usr/bin/env bash
# =============================================================================
# Proxmox Ubuntu 24.04 Cloud-Init Template Creator
# Run from your local Mac or Linux workstation — not on the Proxmox host.
#
# Requirements (local):
#   - curl, ssh, scp, sshpass
#     macOS:  brew install sshpass
#     Linux:  apt-get install sshpass libguestfs-tools
#   - Docker (macOS only — not needed on Linux)
#   - Password-based SSH access to your Proxmox host as root
# =============================================================================
set -euo pipefail
# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
TEMPLATE_ID=9000
TEMPLATE_NAME="ubuntu-2404-cloudinit"
STORAGE="cephSSD"
BRIDGE="vmbr1"
PROXMOX_USER="root"
# PROXMOX_HOST and PROXMOX_PASS are prompted at runtime
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
CHECKSUM_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
IMAGE_FILE="noble-server-cloudimg-amd64.img"
MEMORY=2048
CORES=2
DISK_SIZE="20G"
GITHUB_USER="calebbutcher"
# Remote working directory on the Proxmox host
REMOTE_WORKDIR="/tmp/proxmox-template-build"
# -----------------------------------------------------------------------------
# Cleanup trap — runs on any exit (success or failure)
# Removes local temp files and cleans up remote workdir
# -----------------------------------------------------------------------------
KEYS_FILE=""
KEYS_DIR=""
PROXMOX_HOST=""
PROXMOX_PASS=""
cleanup() {
  [[ -n "$KEYS_FILE" && -f "$KEYS_FILE" ]] && rm -f "$KEYS_FILE"
  [[ -n "$KEYS_DIR" && -d "$KEYS_DIR" ]] && rm -rf "$KEYS_DIR"
  # Only attempt remote cleanup if we have connection details
  if [[ -n "$PROXMOX_HOST" && -n "$PROXMOX_PASS" ]]; then
    echo "==> Cleaning up remote working directory..."
    proxmox_ssh "rm -rf ${REMOTE_WORKDIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# -----------------------------------------------------------------------------
# Helper — run a command on Proxmox over SSH
# -----------------------------------------------------------------------------
proxmox_ssh() {
  sshpass -p "$PROXMOX_PASS" \
    ssh -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=yes \
        -o PubkeyAuthentication=no \
        "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
}
proxmox_scp() {
  sshpass -p "$PROXMOX_PASS" \
    scp -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=yes \
        -o PubkeyAuthentication=no \
        "$@"
}
# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
echo "==> Running preflight checks..."
# Detect OS and set customization strategy
OS_TYPE="$(uname -s)"
ARCH="$(uname -m)"
CONTAINER_BIN=""
if [[ "$OS_TYPE" == "Darwin" ]]; then
  CUSTOMIZE_METHOD="container"
  echo "  Detected: macOS (${ARCH}) — will use a container for virt-customize."
elif [[ "$OS_TYPE" == "Linux" ]]; then
  CUSTOMIZE_METHOD="native"
  echo "  Detected: Linux — will use virt-customize natively."
else
  echo "ERROR: Unsupported OS '${OS_TYPE}'. Run this script on macOS or Linux."
  exit 1
fi
# Check tools common to both platforms
for cmd in curl ssh scp sshpass; do
  if ! command -v "$cmd" &>/dev/null; then
    case "$cmd" in
      sshpass)
        if [[ "$OS_TYPE" == "Darwin" ]]; then
          echo "ERROR: 'sshpass' not found. Install with: brew install sshpass"
        else
          echo "ERROR: 'sshpass' not found. Install with: apt-get install sshpass  (Ubuntu) or dnf install sshpass  (Rocky)"
        fi
        ;;
      *)
        echo "ERROR: Required tool '$cmd' not found on this machine."
        ;;
    esac
    exit 1
  fi
done
# Platform-specific tool checks
if [[ "$CUSTOMIZE_METHOD" == "container" ]]; then
  # Prefer Docker, fall back to Podman
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    CONTAINER_BIN="docker"
    echo "  Container runtime: Docker"
  elif command -v podman &>/dev/null; then
    CONTAINER_BIN="podman"
    echo "  Container runtime: Podman"
  else
    echo "ERROR: No container runtime found. Install one of:"
    echo "       Docker Desktop: https://www.docker.com/products/docker-desktop/"
    echo "       Podman Desktop: https://podman-desktop.io/"
    exit 1
  fi
elif [[ "$CUSTOMIZE_METHOD" == "native" ]]; then
  if ! command -v virt-customize &>/dev/null; then
    echo "==> Installing libguestfs-tools..."
    if command -v apt-get &>/dev/null; then
      apt-get install -y libguestfs-tools
    elif command -v dnf &>/dev/null; then
      dnf install -y libguestfs-tools
    else
      echo "ERROR: Cannot auto-install libguestfs-tools — no supported package manager found."
      echo "       Install it manually and re-run."
      exit 1
    fi
  fi
fi
# -----------------------------------------------------------------------------
# Prompt for Proxmox connection details
# -----------------------------------------------------------------------------
echo ""
echo "Which Proxmox node are you connecting to?"
echo "  Enter the IP address of the target node."
read -r -p "Proxmox IP: " PROXMOX_HOST
if [[ -z "$PROXMOX_HOST" ]]; then
  echo "ERROR: No IP address entered."
  exit 1
fi
read -r -s -p "Password for ${PROXMOX_USER}@${PROXMOX_HOST}: " PROXMOX_PASS
echo ""
if [[ -z "$PROXMOX_PASS" ]]; then
  echo "ERROR: No password entered."
  exit 1
fi
echo "==> Checking SSH connectivity to Proxmox (${PROXMOX_HOST})..."
if ! proxmox_ssh "echo ok" &>/dev/null; then
  echo "ERROR: Cannot SSH to ${PROXMOX_USER}@${PROXMOX_HOST} — check IP and password."
  exit 1
fi
echo "  Connected OK."
echo "==> Checking template ID ${TEMPLATE_ID} is not already in use..."
if proxmox_ssh "qm status ${TEMPLATE_ID}" &>/dev/null; then
  echo "ERROR: VM ID ${TEMPLATE_ID} already exists on Proxmox."
  echo "       Change TEMPLATE_ID or run: ssh ${PROXMOX_USER}@${PROXMOX_HOST} qm destroy ${TEMPLATE_ID}"
  exit 1
fi
# -----------------------------------------------------------------------------
# Download image
# -----------------------------------------------------------------------------
echo "==> Downloading Ubuntu 24.04 cloud image..."
if [[ -f "$IMAGE_FILE" ]]; then
  echo "  Image already exists locally, skipping download."
else
  curl -fL --progress-bar "$IMAGE_URL" -o "$IMAGE_FILE"
fi
# -----------------------------------------------------------------------------
# Verify SHA256 checksum
# -----------------------------------------------------------------------------
echo "==> Verifying SHA256 checksum..."
CHECKSUM_FILE="$(mktemp /tmp/sha256sums.XXXXXX)"
curl -fsSL "$CHECKSUM_URL" -o "$CHECKSUM_FILE"
EXPECTED=$(grep "$IMAGE_FILE" "$CHECKSUM_FILE" | awk '{print $1}')
rm -f "$CHECKSUM_FILE"
if [[ -z "$EXPECTED" ]]; then
  echo "ERROR: Could not find checksum for $IMAGE_FILE in Canonical's SHA256SUMS."
  exit 1
fi
# macOS uses shasum -a 256; Linux uses sha256sum
if command -v sha256sum &>/dev/null; then
  ACTUAL=$(sha256sum "$IMAGE_FILE" | awk '{print $1}')
else
  ACTUAL=$(shasum -a 256 "$IMAGE_FILE" | awk '{print $1}')
fi
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ERROR: Checksum mismatch — image may be corrupted or tampered with."
  echo "  Expected: $EXPECTED"
  echo "  Actual:   $ACTUAL"
  rm -f "$IMAGE_FILE"
  exit 1
fi
echo "  Checksum verified OK."
# -----------------------------------------------------------------------------
# Fetch SSH public keys from GitHub
# -----------------------------------------------------------------------------
echo "==> Fetching SSH public keys from GitHub (@${GITHUB_USER})..."
KEYS_FILE="$(mktemp /tmp/github-keys.XXXXXX)"
if ! curl -fsSL --max-time 30 "https://github.com/${GITHUB_USER}.keys" -o "$KEYS_FILE"; then
  echo "ERROR: Failed to fetch keys from https://github.com/${GITHUB_USER}.keys"
  exit 1
fi
if [[ ! -s "$KEYS_FILE" ]]; then
  echo "ERROR: No SSH keys found for GitHub user @${GITHUB_USER}"
  exit 1
fi
echo "  Found $(wc -l < "$KEYS_FILE") key(s)."
# -----------------------------------------------------------------------------
# Customize the image
#
# Linux:  virt-customize runs natively — fast.
# macOS:  virt-customize runs inside a Docker container (x86 emulation via
#         Rosetta). Expect 3-5 minutes on Apple Silicon.
# -----------------------------------------------------------------------------
KEYS_DIR="$(mktemp -d /tmp/keys-dir.XXXXXX)"
cp "$KEYS_FILE" "${KEYS_DIR}/authorized_keys"
# The virt-customize arguments are identical for both paths
VIRT_CUSTOMIZE_ARGS=(
  --install qemu-guest-agent
  --run-command 'systemctl enable qemu-guest-agent'
  --run-command 'useradd -m -s /bin/bash caleb'
  --run-command 'usermod -aG sudo caleb'
  --run-command 'echo "caleb ALL=(ALL) ALL" > /etc/sudoers.d/caleb'
  --run-command 'chmod 440 /etc/sudoers.d/caleb'
  --run-command 'useradd -m -s /bin/bash ubuntu'
  --run-command 'usermod -aG sudo ubuntu'
  --run-command 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu'
  --run-command 'chmod 440 /etc/sudoers.d/ubuntu'
  --run-command 'apt-get clean'
  --run-command 'cloud-init clean'
  --truncate /etc/machine-id
)
if [[ "$CUSTOMIZE_METHOD" == "native" ]]; then
  echo "==> Customizing image (native virt-customize)..."
  virt-customize \
    -a "$IMAGE_FILE" \
    "${VIRT_CUSTOMIZE_ARGS[@]}" \
    --ssh-inject "caleb:file:${KEYS_DIR}/authorized_keys" \
    --ssh-inject "ubuntu:file:${KEYS_DIR}/authorized_keys"
elif [[ "$CUSTOMIZE_METHOD" == "container" ]]; then
  echo "==> Customizing image via ${CONTAINER_BIN} (Apple Silicon — this may take a few minutes)..."
  ${CONTAINER_BIN} run --rm \
    --platform linux/amd64 \
    -v "$(pwd)/${IMAGE_FILE}:/work/${IMAGE_FILE}" \
    -v "${KEYS_DIR}:/keys:ro" \
    ubuntu:22.04 bash -s << 'DOCKEREOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq libguestfs-tools linux-image-generic 2>/dev/null
export LIBGUESTFS_BACKEND=direct
virt-customize \
  -a /work/${IMAGE_FILE} \
  --install qemu-guest-agent \
  --run-command 'systemctl enable qemu-guest-agent' \
  --run-command 'useradd -m -s /bin/bash caleb' \
  --run-command 'usermod -aG sudo caleb' \
  --run-command 'echo "caleb ALL=(ALL) ALL" > /etc/sudoers.d/caleb' \
  --run-command 'chmod 440 /etc/sudoers.d/caleb' \
  --run-command 'useradd -m -s /bin/bash ubuntu' \
  --run-command 'usermod -aG sudo ubuntu' \
  --run-command 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu' \
  --run-command 'chmod 440 /etc/sudoers.d/ubuntu' \
  --run-command 'apt-get clean' \
  --run-command 'cloud-init clean' \
  --ssh-inject 'caleb:file:/keys/authorized_keys' \
  --ssh-inject 'ubuntu:file:/keys/authorized_keys' \
  --truncate /etc/machine-id
DOCKEREOF
fi
echo "==> Image customization complete."
# -----------------------------------------------------------------------------
# Upload customized image to Proxmox
# -----------------------------------------------------------------------------
echo "==> Uploading customized image to Proxmox (this may take a while)..."
proxmox_ssh "mkdir -p ${REMOTE_WORKDIR}"
proxmox_scp "$IMAGE_FILE" \
    "${PROXMOX_USER}@${PROXMOX_HOST}:${REMOTE_WORKDIR}/${IMAGE_FILE}"
echo "  Upload complete."
# -----------------------------------------------------------------------------
# Create VM and import disk on Proxmox (all via SSH)
# -----------------------------------------------------------------------------
echo "==> Creating VM ${TEMPLATE_ID} on Proxmox..."
proxmox_ssh "qm create ${TEMPLATE_ID} \
  --name ${TEMPLATE_NAME} \
  --memory ${MEMORY} \
  --cores ${CORES} \
  --net0 virtio,bridge=${BRIDGE} \
  --agent enabled=1 \
  --ostype l26 \
  --cpu host \
  --scsihw virtio-scsi-pci"
echo "==> Importing disk to ${STORAGE} (raw format for Ceph)..."
proxmox_ssh "qm importdisk ${TEMPLATE_ID} \
  ${REMOTE_WORKDIR}/${IMAGE_FILE} \
  ${STORAGE} --format raw"
echo "==> Attaching disk..."
proxmox_ssh "qm set ${TEMPLATE_ID} \
  --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on,ssd=1 \
  --boot order=scsi0 \
  --bootdisk scsi0"
echo "==> Configuring cloud-init drive..."
proxmox_ssh "qm set ${TEMPLATE_ID} \
  --ide2 ${STORAGE}:cloudinit \
  --serial0 socket \
  --vga serial0"
proxmox_ssh "qm set ${TEMPLATE_ID} \
  --citype nocloud \
  --ipconfig0 ip=dhcp"
echo "==> Resizing disk to ${DISK_SIZE}..."
proxmox_ssh "qm resize ${TEMPLATE_ID} scsi0 ${DISK_SIZE}"
echo "==> Converting to template..."
proxmox_ssh "qm template ${TEMPLATE_ID}"
# -----------------------------------------------------------------------------
# Prompt to remove local image file
# -----------------------------------------------------------------------------
echo ""
read -r -p "==> Remove local image file '${IMAGE_FILE}'? [y/N] " response
if [[ "${response,,}" == "y" ]]; then
  rm -f "$IMAGE_FILE"
  echo "  Removed."
else
  echo "  Kept — re-runs will skip the download step."
fi
echo ""
echo "============================================================"
echo "  Template created successfully!"
echo "  ID:      ${TEMPLATE_ID}"
echo "  Name:    ${TEMPLATE_NAME}"
echo "  Storage: ${STORAGE}"
echo "  Bridge:  ${BRIDGE}"
echo ""
echo "  Next steps:"
echo "  - Verify in Proxmox UI: the VM should show a template icon"
echo "  - Inspect: ssh ${PROXMOX_USER}@${PROXMOX_HOST} 'qm cloudinit dump ${TEMPLATE_ID} user'"
echo "  - Use template ID ${TEMPLATE_ID} in your Terraform config"
echo "============================================================"
