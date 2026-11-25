#!/bin/sh
# tar-progress.sh — one-line progress bar for GNU tar --checkpoint-action.
# Env (set by the caller): TAR_CHECKPOINT (set by tar itself),
# TOTAL_BYTES (total uncompressed bytes), PROGRESS_LABEL (e.g. backup).
# One tar record is 10240 bytes. Prints "\r<label>: [####----] 42%"
# on the same line; the caller prints the final newline.
b=$((TAR_CHECKPOINT * 10240))
p=$((b * 100 / TOTAL_BYTES))
[ "$p" -gt 100 ] && p=100
f=$(printf '%*s' $((p / 5)) '' | tr ' ' '#')
e=$(printf '%*s' $((20 - p / 5)) '' | tr ' ' '-')
printf '\r%s: [%s%s] %d%%' "$PROGRESS_LABEL" "$f" "$e" "$p"
