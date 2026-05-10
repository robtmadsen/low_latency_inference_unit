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
#   .github/plan/dvcon/spec/itch_field_extract_spec.md (must exist before running)
#
# The commit message is intentionally neutral ("initial") so the agent sees
# no signal about bugs or experiment phases.
set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
PHASE=${1:?usage: prepare_experiment_repo.sh [phase1|phase2] [GITHUB_USER]}
GH_USER=${2:-${GITHUB_USER:?pass GitHub user/org as arg 2 or set GITHUB_USER}}

REPO_NAME="dv-exp-${PHASE}"
REPO_SLUG="${GH_USER}/${REPO_NAME}"
REPO_URL="git@github.com:${REPO_SLUG}.git"

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"   # repo root

SPEC_SRC="$MAIN_REPO/.github/plan/dvcon/spec/itch_field_extract_spec.md"
PKG_SRC="$MAIN_REPO/rtl/lliu_pkg.sv"

case "$PHASE" in
    phase1) DUT_SRC="$MAIN_REPO/rtl/itch_field_extract.sv" ;;
    phase2) DUT_SRC="$MAIN_REPO/rtl/buggy/itch_field_extract.sv" ;;
    *) echo "ERROR: phase must be 'phase1' or 'phase2'" >&2; exit 1 ;;
esac

# ── Pre-flight checks ────────────────────────────────────────────────────────
for f in "$PKG_SRC" "$DUT_SRC" "$SPEC_SRC"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file not found: $f" >&2
        [ "$f" = "$SPEC_SRC" ] && echo "       Create .github/plan/dvcon/spec/itch_field_extract_spec.md first." >&2
        exit 1
    fi
done

echo "Phase  : $PHASE"
echo "DUT    : $DUT_SRC"
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
cp "$PKG_SRC"  rtl/lliu_pkg.sv
cp "$DUT_SRC"  rtl/itch_field_extract.sv
cp "$SPEC_SRC" spec/itch_field_extract_spec.md

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
