#!/bin/sh
trap '' TERM
/bin/sleep 30 >/dev/null 2>&1 &
child="$!"
printf '%s\n' "$child"
wait "$child"
