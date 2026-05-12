#!/usr/bin/env bash
# prepare_experiment_repo.sh
#
# Create a fresh private GitHub repo for one experiment phase and populate it
# with a single orphan commit containing only rtl/ and spec/.
# No history, no methodology artefacts — the agent sees a clean slate.
#
# Requires: git, gh (GitHub CLI, already authenticated)
#
# Usage:
#   bash prepare_experiment_repo.sh [phase1|phase2] [GITHUB_ORG_OR_USER]
#
# The repo name is derived automatically: dv-exp-<phase>.
# GITHUB_ORG_OR_USER defaults to the value of $GITHUB_USER env var.
#
# Example:
#   bash prepare_experiment_repo.sh phase2 robtmadsen
#
# Files sourced from the main repo:
#   rtl/lliu_pkg.sv                                   (always clean)
#   rtl/itch_field_extract.sv                         (phase1 — clean DUT)
#   rtl/buggy/itch_field_extract.sv                   (phase2 — buggy DUT)
#   rtl/buggy/phase3/*.sv                             (phase3 — buggy multi-module DUT)
#   .github/plan/dvcon/spec/itch_field_extract_spec.md (phase1/2)
#   .github/arch/rtl/{lliu_core,dot_product_engine,   (phase3 — one file per module)
#     bfloat16_mul,fp32_acc,weight_mem,output_buffer}.md
#
# The commit message is intentionally neutral ("initial") so the agent sees
# no signal about bugs or experiment phases.
set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
PHASE=${1:?usage: prepare_experiment_repo.sh [phase1|phase2|phase3] [GITHUB_USER]}
GH_USER=${2:-${GITHUB_USER:?pass GitHub user/org as arg 2 or set GITHUB_USER}}

REPO_NAME="dv-exp-${PHASE}"
REPO_SLUG="${GH_USER}/${REPO_NAME}"
REPO_URL="git@github.com:${REPO_SLUG}.git"

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"   # repo root

PKG_SRC="$MAIN_REPO/rtl/lliu_pkg.sv"

case "$PHASE" in
    phase1)
        DUT_FILES=("$MAIN_REPO/rtl/itch_field_extract.sv")
        SPEC_FILES=("$MAIN_REPO/.github/plan/dvcon/spec/itch_field_extract_spec.md")
        ;;
    phase2)
        DUT_FILES=("$MAIN_REPO/rtl/buggy/itch_field_extract.sv")
        SPEC_FILES=("$MAIN_REPO/.github/plan/dvcon/spec/itch_field_extract_spec.md")
        ;;
    phase3)
        DUT_FILES=(
            "$MAIN_REPO/rtl/buggy/phase3/lliu_core.sv"
            "$MAIN_REPO/rtl/buggy/phase3/dot_product_engine.sv"
            "$MAIN_REPO/rtl/buggy/phase3/bfloat16_mul.sv"
            "$MAIN_REPO/rtl/buggy/phase3/fp32_acc.sv"
            "$MAIN_REPO/rtl/buggy/phase3/weight_mem.sv"
            "$MAIN_REPO/rtl/buggy/phase3/output_buffer.sv"
        )
        SPEC_FILES=(
            "$MAIN_REPO/.github/arch/rtl/lliu_core.md"
            "$MAIN_REPO/.github/arch/rtl/dot_product_engine.md"
            "$MAIN_REPO/.github/arch/rtl/bfloat16_mul.md"
            "$MAIN_REPO/.github/arch/rtl/fp32_acc.md"
            "$MAIN_REPO/.github/arch/rtl/weight_mem.md"
            "$MAIN_REPO/.github/arch/rtl/output_buffer.md"
        )
        ;;
    *) echo "ERROR: phase must be 'phase1', 'phase2', or 'phase3'" >&2; exit 1 ;;
esac

# ── Pre-flight checks ────────────────────────────────────────────────────────
for f in "$PKG_SRC" "${DUT_FILES[@]}" "${SPEC_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file not found: $f" >&2
        exit 1
    fi
done

echo "Phase  : $PHASE"
echo "DUT    : ${DUT_FILES[*]}"
echo "Repo   : $REPO_SLUG (will be created as private)"
echo ""

# ── Create GitHub repo (fails gracefully if it already exists) ───────────────
if gh repo view "$REPO_SLUG" &>/dev/null; then
    echo "Repo $REPO_SLUG already exists — will force-push the new orphan commit."
else
    echo "Creating private repo $REPO_SLUG ..."
    gh repo create "$REPO_SLUG" --private
fi
echo ""

# ── Build orphan repo in a temp dir ─────────────────────────────────────────
TMPDIR_WORK=$(mktemp -d)
trap "rm -rf '$TMPDIR_WORK'" EXIT

cd "$TMPDIR_WORK"
git init experiment
cd experiment

# Create an orphan main branch (no parent commits)
git checkout --orphan main

# Populate the tree
mkdir -p rtl spec
cp "$PKG_SRC" rtl/lliu_pkg.sv
for f in "${DUT_FILES[@]}"; do cp "$f" rtl/; done
for f in "${SPEC_FILES[@]}"; do cp "$f" spec/; done

# Single neutral commit — no mention of phase, bugs, or experiment
git add .
git -c user.name="experimenter" \
    -c user.email="experimenter@local" \
    commit -m "initial"

# ── Push ─────────────────────────────────────────────────────────────────────
git remote add origin "$REPO_URL"
git push --force origin main

echo ""
echo "=== Done ==="
echo "Experiment repo at $REPO_URL has one commit on main."
echo ""
echo "VMs should clone with:"
echo "  git clone --depth 1 $REPO_URL ~/experiment"
