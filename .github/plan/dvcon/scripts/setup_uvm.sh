#!/usr/bin/env bash
# setup_uvm.sh — UVM-only extras for vm-uvm
# Run AFTER setup_common.sh completes
# Run as: bash setup_uvm.sh 2>&1 | tee /tmp/setup_uvm.log
set -euo pipefail

echo "=== [1/1] Accellera UVM source ==="
if [ -d ~/uvm-core ]; then
    echo "uvm-core already cloned, pulling latest."
    git -C ~/uvm-core pull
else
    git clone https://github.com/accellera-official/uvm-core.git ~/uvm-core
fi

# Add UVM_HOME to ~/.bashrc if not already there
if ! grep -q "UVM_HOME" ~/.bashrc; then
    echo 'export UVM_HOME=$HOME/uvm-core/src' >> ~/.bashrc
fi

# Add to /etc/environment for non-login shells
if ! sudo grep -q "UVM_HOME" /etc/environment; then
    echo "UVM_HOME=/home/azureuser/uvm-core/src" | sudo tee -a /etc/environment
fi

echo "UVM_HOME set to: ~/uvm-core/src"
ls ~/uvm-core/src/uvm_pkg.sv && echo "uvm_pkg.sv present — OK"

echo ""
echo "=== setup_uvm.sh DONE ==="
