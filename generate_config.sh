#!/bin/bash

OUTPUT_FILE="devicestate.json"
# Accept Trigger Mode as 1st argument (Default to "Off" if not provided)
TRIGGER_MODE=${1:-"Off"} 

# --- FIXED SETTINGS (Modify these if image is still too bright/dark) ---
EXPOSURE_TIME=250   # Microseconds (Try 100 if still white, 1000 if too dark)
GAIN_VAL=0.0        # Keep at 0 for cleanest laser signal
WIDTH=640
HEIGHT=480
FPS="30/1"
# -----------------------------------------------------------------------

# 1. Check for jq
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. sudo apt install jq"
    exit 1
fi

# 2. Find Camera
CAM_INFO=$(tcam-ctrl -l | head -n 1)
if [[ -z "$CAM_INFO" ]]; then
    echo "Error: No camera found!"
    exit 1
fi

SERIAL=$(echo "$CAM_INFO" | grep -oP 'Serial: \K\d+')
echo "Found Camera: $SERIAL"
echo "Applying Settings -> Trigger: $TRIGGER_MODE | Exposure: $EXPOSURE_TIME | Gain: $GAIN_VAL"

# 3. Get Base Properties
# We read the camera's current state, but we will overwrite the important ones below
PROPERTIES=$(tcam-ctrl --save-json "$SERIAL")

if [[ -z "$PROPERTIES" ]]; then
    echo "Error: Failed to read properties."
    exit 1
fi

# 4. Construct Final JSON
# We use jq to merge our fixed settings ON TOP of the camera properties
echo "Generating $OUTPUT_FILE..."

jq -n \
  --arg serial "$SERIAL" \
  --arg pipe "tcambin name=tcam0 ! {0} ! appsink name=sink sync=false drop=true max-buffers=1" \
  --argjson w "$WIDTH" \
  --argjson h "$HEIGHT" \
  --arg fps "$FPS" \
  --arg trig "$TRIGGER_MODE" \
  --argjson exp "$EXPOSURE_TIME" \
  --argjson gain "$GAIN_VAL" \
  --argjson props "$PROPERTIES" \
  '{
    pipeline: $pipe,
    serial: ($serial | tonumber),
    height: $h,
    width: $w,
    framerate: $fps,
    properties: ($props + { 
        "TriggerMode": $trig,
        "ExposureAuto": "Off",
        "GainAuto": "Off",
        "ExposureTime": $exp,
        "Gain": $gain
    })
  }' > "$OUTPUT_FILE"

echo "Done! Configuration saved to $OUTPUT_FILE"
