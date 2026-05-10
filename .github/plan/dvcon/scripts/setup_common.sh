#!/usr/bin/env bash
# setup_common.sh — Install software stack common to both vm-cocotb and vm-uvm
# Run as: bash setup_common.sh 2>&1 | tee /tmp/setup_common.log
set -euo pipefail

echo "=== [1/5] System packages ==="
sudo apt-get update -qq
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update -qq
sudo apt-get install -y \
    git curl wget \
    g++ make \
    autoconf flex bison libfl-dev zlib1g-dev help2man \
    python3.12 python3.12-venv python3-pip \
    lcov \
    tmux

echo "=== [2/5] Verilator 5.046 from source ==="
if verilator --version 2>/dev/null | grep -q "5.046"; then
    echo "Verilator 5.046 already installed, skipping build."
else
    git clone --depth 1 --branch v5.046 \
        https://github.com/verilator/verilator.git ~/verilator-src
    cd ~/verilator-src
    autoconf
    ./configure --prefix=/usr/local
    make -j2
    sudo make install
    cd ~
fi
verilator --version

echo "=== [3/5] Python venv + cocotb ==="
python3.12 -m venv ~/venv
source ~/venv/bin/activate
pip install --upgrade pip
pip install cocotb numpy
deactivate

echo "=== [4/5] Node.js 22.x ==="
if node --version 2>/dev/null | grep -q "v22"; then
    echo "Node.js 22 already installed, skipping."
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
node --version

echo "=== [5/5] Claude Code CLI ==="
sudo npm install -g @anthropic-ai/claude-code
claude --version

echo ""
echo "=== setup_common.sh DONE ==="
