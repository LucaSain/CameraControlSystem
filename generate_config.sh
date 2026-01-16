#!/bin/bash

OUTPUT_FILE="devicestate.json"

# 1. Check if 'jq' is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it first:"
    echo "sudo apt install jq"
    exit 1
fi

# 2. Find Camera
echo "Searching for TIS cameras..."
# Get the first camera line found
CAM_INFO=$(tcam-ctrl -l | head -n 1)

if [[ -z "$CAM_INFO" ]]; then
    echo "Error: No camera found! Please check connection."
    exit 1
fi

# Extract Serial Number using grep/regex
# Matches "Serial: <digits>" and cuts out the digits
SERIAL=$(echo "$CAM_INFO" | grep -oP 'Serial: \K\d+')

if [[ -z "$SERIAL" ]]; then
    echo "Error: Could not parse serial number."
    exit 1
fi

echo "Found Camera: $CAM_INFO"
echo "Using Serial: $SERIAL"

# 3. Prompt for Stream Settings (Defaults provided)
read -p "Enter Width (default 640): " WIDTH
WIDTH=${WIDTH:-640}

read -p "Enter Height (default 480): " HEIGHT
HEIGHT=${HEIGHT:-480}

read -p "Enter Framerate (default 30/1): " FPS
FPS=${FPS:-"30/1"}

# 4. Get Current Camera Properties
echo "Reading current camera properties..."
PROPERTIES=$(tcam-ctrl --save-json "$SERIAL")

if [[ -z "$PROPERTIES" ]]; then
    echo "Error: Failed to read properties from camera."
    exit 1
fi

# 5. Construct Final JSON
# We use jq to construct the object structure perfectly
# Note: serial is converted to a number | tonumber
echo "Generating $OUTPUT_FILE..."

jq -n \
  --arg serial "$SERIAL" \
  --arg pipe "tcambin name=tcam0 ! {0} ! appsink name=sink sync=false drop=true max-buffers=1" \
  --argjson w "$WIDTH" \
  --argjson h "$HEIGHT" \
  --arg fps "$FPS" \
  --argjson props "$PROPERTIES" \
  '{
    pipeline: $pipe,
    serial: ($serial | tonumber),
    height: $h,
    width: $w,
    framerate: $fps,
    properties: $props
  }' > "$OUTPUT_FILE"

echo "Done! Configuration saved to $OUTPUT_FILE"
