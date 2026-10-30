#!/bin/sh
# Run from any directory. Arguments are passed to Compose, e.g. -f compose.test.yaml.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
docker compose "$@" ps
docker compose "$@" exec -T audio python3 -c 'import json; print(json.dumps(json.load(open("/run/lan-audio/status.json")), indent=2, ensure_ascii=False))'
docker compose "$@" exec -T audio pactl --server=unix:/run/lan-audio/pulse.sock list short modules
