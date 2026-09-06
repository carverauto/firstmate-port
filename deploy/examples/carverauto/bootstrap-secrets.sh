#!/usr/bin/env bash
set -euo pipefail

export ADMIN_EMAIL=captain@localhost
exec bash "$(dirname "$0")/../../bootstrap-secrets.sh"
