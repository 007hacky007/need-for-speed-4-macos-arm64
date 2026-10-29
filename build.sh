#!/bin/sh
set -eu
exec python3 -B "$(dirname "$0")/tools/build_app.py" "$@"
