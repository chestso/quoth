#!/bin/sh
# Mock crush CLI: writes received args and stdin to $CRUSH_CAPTURE_FILE.
# Called as: mock-crush.sh run [--continue] [prompt]

CAPTURE_FILE="${CRUSH_CAPTURE_FILE}"

if [ -z "$CAPTURE_FILE" ]; then
	echo "CRUSH_CAPTURE_FILE not set" >&2
	exit 1
fi

# Capture command-line arguments
echo "ARGS:" >"$CAPTURE_FILE"
for arg in "$@"; do
	echo "  $arg" >>"$CAPTURE_FILE"
done

# Capture stdin if any content is piped
stdin_content=$(cat 2>/dev/null)
if [ -n "$stdin_content" ]; then
	echo "STDIN:" >>"$CAPTURE_FILE"
	echo "$stdin_content" >>"$CAPTURE_FILE"
fi

# Print a fake response to stdout
echo "mock response"
