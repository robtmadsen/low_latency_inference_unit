# LLIU devcontainer — Verilator 5.046 + Python 3.12 + UVM
#
# Installs Verilator from source (same version as CI) so that the
# UVM testbench can be compiled inside Codespaces without killing a
# MacBook Air.  UVM source is fetched in post-create.sh so the layer
# stays cacheable.

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# ── System build deps ───────────────────────────────────────────────
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        # Verilator build deps
        git autoconf g++ flex bison \
        libfl2 libfl-dev zlib1g-dev help2man \
        # Simulation runtime deps
        libgcc-s1 \
        # Python 3.12 (already in ubuntu-24.04, but ensure pip is present)
        python3.12 python3.12-dev python3-pip python3-venv \
        # Misc dev tools
        cmake make curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Build Verilator 5.046 from source ───────────────────────────────
# Installed to /usr/local so it is on PATH for all users without any
# extra profile changes.
RUN git clone --depth 1 --branch v5.046 \
        https://github.com/verilator/verilator.git /tmp/verilator-src && \
    cd /tmp/verilator-src && \
    autoconf && \
    ./configure --prefix=/usr/local && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /tmp/verilator-src

# ── Python packages ─────────────────────────────────────────────────
RUN pip3 install --no-cache-dir --break-system-packages \
        "cocotb>=2.0" numpy

# ── Convenience aliases for the vscode user ─────────────────────────
RUN echo 'export UVM_HOME=/opt/uvm-reference/src' >> /etc/profile.d/lliu.sh && \
    chmod +x /etc/profile.d/lliu.sh
