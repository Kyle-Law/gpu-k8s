#!/usr/bin/env bash
# Base packages used by the other scripts.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

step "Base tools (curl, gpg, jq, git, bash-completion)"
$SUDO apt-get update -y
$SUDO apt-get install -y curl gpg jq git bash-completion
