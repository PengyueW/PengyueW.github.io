#!/usr/bin/env bash
# Start World Brief. First run creates a virtualenv and installs dependencies; later runs
# reinstall only when requirements.txt has changed.
set -e
cd "$(dirname "$0")"
STAMP=".venv/.requirements-sha"
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
SHA="$(shasum requirements.txt | cut -d' ' -f1)"
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$SHA" ]; then
  .venv/bin/pip install -q -r requirements.txt && echo "$SHA" > "$STAMP"
fi
PORT="${PORT:-8000}"
echo "World Brief -> http://localhost:$PORT   (first brief takes a few minutes while feeds are fetched)"
exec .venv/bin/uvicorn backend.app:app --host 127.0.0.1 --port "$PORT"
