#!/bin/sh
trap 'printf terminated > "$MARKER_PATH"; kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM
/bin/sleep 30 &
child="$!"
printf '%s\n' "$child"
wait "$child"
