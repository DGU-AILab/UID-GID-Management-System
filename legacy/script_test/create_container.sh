#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${PROJECT_ROOT}/legacy/script/create_container.sh" --dry-run "$@"
