{ pkgs, lib, ... }:
{
  env.SEED_VM_NAME = "SEEDUbuntu16.04";

  scripts.seed-vm-setup.exec = ''
    set -euo pipefail

    VM_NAME="''${SEED_VM_NAME:?}"
    VM_DIR="''${SEED_VM_DIR:-$DEVENV_ROOT/.seed-vm}"
    ZIP_URL="https://seed.nyc3.cdn.digitaloceanspaces.com/SEEDUbuntu-16.04-32bit.zip"
    ZIP_MD5="12c48542c29c233580a23589b72b71b8"
    ZIP_FILE="$VM_DIR/SEEDUbuntu-16.04-32bit.zip"

    if ! command -v VBoxManage &>/dev/null; then
      echo "ERROR: VBoxManage not found. Add this to your NixOS config and rebuild:" >&2
      echo "  virtualisation.virtualbox.host = {" >&2
      echo "    enable = true;" >&2
      echo "    enableKvm = true;" >&2
      echo "    addNetworkInterface = false;" >&2
      echo "  };" >&2
      exit 1
    fi

    mkdir -p "$VM_DIR"

    VMDK_FILE=""
    EXTRACT_DIR=$(find "$VM_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
    if [ -n "$EXTRACT_DIR" ]; then
      VMDK_FILE=$(find "$EXTRACT_DIR" -maxdepth 1 -name "*.vmdk" ! -name "*-s*.vmdk" -print -quit 2>/dev/null || true)
    fi

    if VBoxManage showvminfo "$VM_NAME" &>/dev/null && [ -f "$VMDK_FILE" ]; then
      echo "✓ SEED Labs VM '$VM_NAME' is ready."
      exit 0
    fi

    VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true

    if [ ! -f "$ZIP_FILE" ]; then
      echo "Downloading SEED Labs VM (Ubuntu 16.04 32-bit)..."
      ${lib.getExe pkgs.axel} -n 4 -o "$ZIP_FILE" "$ZIP_URL"
    else
      echo "ZIP already cached at $ZIP_FILE"
    fi

    echo "Verifying MD5 checksum..."
    echo "$ZIP_MD5  $ZIP_FILE" | md5sum -c || {
      echo "Checksum mismatch! Removing corrupted download."
      rm -f "$ZIP_FILE"
      exit 1
    }

    echo "Extracting VM..."
    ${lib.getExe pkgs.unzip} -o -d "$VM_DIR" "$ZIP_FILE"

    EXTRACT_DIR=$(find "$VM_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    VMDK_FILE=$(find "$EXTRACT_DIR" -maxdepth 1 -name "*.vmdk" ! -name "*-s*.vmdk" -print -quit)

    if [ -z "$VMDK_FILE" ]; then
      echo "ERROR: No main .vmdk file found in the extracted archive." >&2
      exit 1
    fi

    rm -f "$ZIP_FILE"

    echo "Creating VM '$VM_NAME'..."
    VBoxManage createvm --name "$VM_NAME" --ostype "Ubuntu" --register
    VBoxManage modifyvm "$VM_NAME" --memory 1024 --vram 128 --cpus 1
    VBoxManage storagectl "$VM_NAME" --name "SATA" --add sata --controller IntelAhci
    VBoxManage storageattach "$VM_NAME" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "$VMDK_FILE"
    VBoxManage modifyvm "$VM_NAME" --nic1 nat
    VBoxManage modifyvm "$VM_NAME" --natpf1 "guestssh,tcp,,2222,,22"

    echo "✓ SEED Labs VM '$VM_NAME' is ready!"
  '';

  scripts.seed-vm-start.exec = ''
    set -euo pipefail

    VM_NAME="''${SEED_VM_NAME:-SEEDUbuntu16.04}"

    if ! VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
      echo "VM '$VM_NAME' not registered. Running seed-vm-setup..."
      seed-vm-setup
    fi

    if ! VBoxManage showvminfo "$VM_NAME" | grep -q "guestssh"; then
      echo "Adding SSH port forwarding (host:2222 -> guest:22)..."
      VBoxManage modifyvm "$VM_NAME" --natpf1 "guestssh,tcp,,2222,,22"
    fi

    echo "Starting VM '$VM_NAME'..."
    VBoxManage startvm "$VM_NAME"
  '';

  enterShell = ''
    echo "computer_security — SEED Labs environment"
    echo "Commands:"
    echo "  seed-vm-setup   Download and import the SEED Labs VM (idempotent)"
    echo "  seed-vm-start   Start the SEED Labs VM (runs setup if needed)"
    echo ""
    echo "VM stored in: ''${SEED_VM_DIR:-$DEVENV_ROOT/.seed-vm}"
  '';
}
