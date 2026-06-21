#!/usr/bin/env bash
#
# deploy-all.sh — run a Terraform action across every pattern module.
#
# Each pattern under patterns/ is a self-contained root module. This wrapper runs
# the chosen Terraform action (plan by default) against each one in turn so the
# whole catalogue can be validated, planned, applied, or destroyed in one command.
#
# Patterns are independent: a failure in one is reported and, unless --keep-going
# is set, stops the run with a non-zero exit so CI fails loudly.
#
# Usage:
#   scripts/deploy-all.sh [ACTION] [options]
#
# Actions:
#   validate   terraform init -backend=false && terraform validate   (no creds)
#   plan       terraform init && terraform plan                      (default)
#   apply      terraform init && terraform apply -auto-approve
#   destroy    terraform init && terraform destroy -auto-approve
#
# Options:
#   -p, --pattern NAME   Only act on patterns/NAME (repeatable).
#   -k, --keep-going     Continue after a pattern fails; exit non-zero at the end.
#   -h, --help           Show this help and exit.
#
# Examples:
#   scripts/deploy-all.sh validate
#   scripts/deploy-all.sh plan -p saga -p retry-backoff
#   scripts/deploy-all.sh apply --keep-going

set -euo pipefail

# --------------------------------------------------------------------------- #
# Setup
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATTERNS_DIR="${REPO_ROOT}/patterns"

# Colour output only when stdout is a terminal that supports it.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD="$(tput bold)"; RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; RESET="$(tput sgr0)"
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

ACTION="plan"
KEEP_GOING="false"
SELECTED=()
FAILED=()

log()  { printf '%s\n' "${BLUE}${BOLD}==>${RESET} $*"; }
ok()   { printf '%s\n' "${GREEN}${BOLD}  ✓${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}${BOLD}  !${RESET} $*" >&2; }
err()  { printf '%s\n' "${RED}${BOLD}  ✗${RESET} $*" >&2; }

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cleanup() {
  local code=$?
  if [[ ${code} -ne 0 && ${#FAILED[@]} -eq 0 ]]; then
    err "deploy-all.sh exited unexpectedly (code ${code})."
  fi
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #

while [[ $# -gt 0 ]]; do
  case "$1" in
    validate|plan|apply|destroy) ACTION="$1"; shift ;;
    -p|--pattern) [[ $# -ge 2 ]] || { err "$1 requires a value"; exit 2; }; SELECTED+=("$2"); shift 2 ;;
    -k|--keep-going) KEEP_GOING="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

command -v terraform >/dev/null 2>&1 || { err "terraform is not installed or not on PATH."; exit 1; }
[[ -d "${PATTERNS_DIR}" ]] || { err "patterns directory not found: ${PATTERNS_DIR}"; exit 1; }

# --------------------------------------------------------------------------- #
# Discover patterns
# --------------------------------------------------------------------------- #

discover_patterns() {
  # A pattern is any directory under patterns/ that contains a main.tf.
  local dir
  for dir in "${PATTERNS_DIR}"/*/; do
    [[ -f "${dir}main.tf" ]] && basename "${dir}"
  done
}

mapfile -t ALL_PATTERNS < <(discover_patterns | sort)

if [[ ${#SELECTED[@]} -gt 0 ]]; then
  TARGETS=()
  for name in "${SELECTED[@]}"; do
    if [[ -f "${PATTERNS_DIR}/${name}/main.tf" ]]; then
      TARGETS+=("${name}")
    else
      err "no deployable pattern named '${name}' (missing patterns/${name}/main.tf)"
      exit 1
    fi
  done
else
  TARGETS=("${ALL_PATTERNS[@]}")
fi

[[ ${#TARGETS[@]} -gt 0 ]] || { err "no patterns with a main.tf were found."; exit 1; }

# --------------------------------------------------------------------------- #
# Run the action per pattern
# --------------------------------------------------------------------------- #

run_pattern() {
  local name="$1"
  local dir="${PATTERNS_DIR}/${name}"
  log "${name}: terraform ${ACTION}"

  (
    cd "${dir}"
    case "${ACTION}" in
      validate)
        terraform init -backend=false -input=false -no-color >/dev/null
        terraform validate -no-color
        ;;
      plan)
        terraform init -input=false -no-color >/dev/null
        terraform plan -input=false -no-color
        ;;
      apply)
        terraform init -input=false -no-color >/dev/null
        terraform apply -auto-approve -input=false -no-color
        ;;
      destroy)
        terraform init -input=false -no-color >/dev/null
        terraform destroy -auto-approve -input=false -no-color
        ;;
    esac
  )
}

log "${BOLD}Action:${RESET} ${ACTION}   ${BOLD}Patterns:${RESET} ${TARGETS[*]}"

for name in "${TARGETS[@]}"; do
  if run_pattern "${name}"; then
    ok "${name}: ${ACTION} succeeded"
  else
    err "${name}: ${ACTION} failed"
    FAILED+=("${name}")
    [[ "${KEEP_GOING}" == "true" ]] || { err "stopping (use --keep-going to continue)."; exit 1; }
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  err "completed with failures: ${FAILED[*]}"
  exit 1
fi

ok "all patterns: ${ACTION} succeeded (${#TARGETS[@]} module(s))."
