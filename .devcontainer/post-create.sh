#!/usr/bin/env bash
# post-create.sh — runs once after the devcontainer is created.
#
# Fetches the Accellera UVM reference source to /opt/uvm-reference so
# the UVM testbench can be compiled immediately:
#
#   make -C tb/uvm SIM=verilator UVM_HOME=/opt/uvm-reference/src compile
#
set -euo pipefail

UVM_DEST=/opt/uvm-reference

if [ ! -d "$UVM_DEST/src" ]; then
    echo "==> Cloning Accellera UVM reference source to $UVM_DEST ..."
    sudo git clone --depth 1 \
        https://github.com/accellera-official/uvm-core.git \
        "$UVM_DEST"
    echo "==> UVM source ready: $UVM_DEST/src/uvm_pkg.sv"
else
    echo "==> UVM source already present at $UVM_DEST/src — skipping clone."
fi

# Ensure the /opt directory is readable by the vscode user.
sudo chown -R "$(id -u):$(id -g)" "$UVM_DEST"

echo ""
echo "=========================================="
echo " LLIU devcontainer ready."
echo ""
echo " Verilator: $(verilator --version | head -1)"
echo " Python:    $(python3.12 --version)"
echo " UVM_HOME:  $UVM_DEST/src"
echo ""
echo " Compile UVM TB:"
echo "   make -C tb/uvm SIM=verilator UVM_HOME=$UVM_DEST/src compile"
echo ""
echo " Run all UVM tests:"
echo "   export UVM_HOME=$UVM_DEST/src"
echo "   python3 scripts/run_uvm_regression.py"
echo "=========================================="
