#!/bin/sh
set -e

# Default to running the first app if no argument is provided
if [ "$1" = "converter" ]; then
    exec /app/bin/converter
elif [ "$1" = "streamer" ]; then
    exec /app/bin/streamer
elif [ "$1" = "uploader" ]; then
    exec /app/bin/uploader
else
    echo "Usage: $0 {converter|streamer|uploader}"
    exit 1
fi
