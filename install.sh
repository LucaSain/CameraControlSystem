#!/bin/bash

# ==============================================================================
#  Laser Profiler Setup Script (Debian 11 / Bullseye)
# ==============================================================================

# Helper function for colored output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. OS Check (Debian 11 / Bullseye)
log_info "Checking OS version..."
if grep -q "bullseye" /etc/os-release; then
    log_info "OS is Debian 11 (Bullseye). Proceeding..."
else
    log_err "Detected OS is NOT Debian 11 (Bullseye)."
    cat /etc/os-release
    read -p "Do you want to continue anyway? (y/N) " choice
    if [[ "$choice" != "y" ]]; then
        exit 1
    fi
fi

# 2. Update and Upgrade
log_info "Updating system packages..."
sudo apt-get update && sudo apt-get -y upgrade

# 3. Install Core Dependencies
log_info "Installing Git, Python3, Pip, and System Tools..."
sudo apt-get install -y git python3-pip python3-venv python3-dev wget curl jq unzip

# 4. Install The Imaging Source Drivers
# We create a temporary directory to keep things clean
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
log_info "Downloading TIS Camera Drivers..."

# Define URLs
URL1="https://dl.theimagingsource.com/7366c5ab-631a-5e7a-85f4-decf5ae86a07/tiscamera_1.1.0.4137_armhf.deb"
URL2="https://dl.theimagingsource.com/72ff2659-344d-57c8-b96b-4540afc4b629/tiscamera-tcamprop_1.0.0.4137_armhf.deb"
URL3="https://dl.theimagingsource.com/f32194fe-7faa-50e3-94c4-85c504dbdea6/tcam-gigetool_0.3.0_armhf.deb" 

# Download
wget -O tiscamera.deb "$URL1"
wget -O tcamprop.deb "$URL2"
wget -O gigetool.deb "$URL3"

log_info "Installing Drivers..."
# Install using apt to resolve internal dependencies automatically
sudo apt-get install -y ./tiscamera.deb ./tcamprop.deb ./gigetool.deb

# 5. Install GStreamer & Python Science Stack
log_info "Installing GStreamer, OpenCV, and Scipy..."
sudo apt-get install -y \
    libgstreamer1.0-0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-tools \
    gstreamer1.0-x \
    gstreamer1.0-alsa \
    gstreamer1.0-gl \
    gstreamer1.0-gtk3 \
    gstreamer1.0-qt5 \
    gstreamer1.0-pulseaudio \
    python3-opencv \
    python3-scipy \
    python3-gst-1.0 \
    python3-gi

# 6. Clone Github Repo
echo ""
read -p "Enter installation directory (default: ~/code): " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-"$HOME/code"}

read -p "Enter GitHub Repo URL (e.g., https://github.com/LucaSain/CameraControlSystem.git): " REPO_URL

if [[ -z "$REPO_URL" ]]; then
    log_err "No Repo URL provided. Exiting."
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# Extract repo name from URL to find the folder name
REPO_NAME=$(basename "$REPO_URL" .git)

if [ -d "$REPO_NAME" ]; then
    log_warn "Directory $REPO_NAME already exists. Pulling latest changes..."
    cd "$REPO_NAME"
    git pull
else
    log_info "Cloning repository..."
    git clone "$REPO_URL"
    cd "$REPO_NAME"
fi

PROJECT_ROOT=$(pwd)

# 7. Create Virtual Environment (.env) & Install Requirements
log_info "Setting up Python Virtual Environment in .env..."
python3 -m venv .env
source .env/bin/activate

if [ -f "requirements.txt" ]; then
    log_info "Installing requirements.txt..."
    pip install --upgrade pip
    pip install -r requirements.txt
else
    log_warn "requirements.txt not found! Installing default dependencies manually..."
    pip install flask numpy adafruit-circuitpython-tmp117 adafruit-blinka RPi.GPIO
fi

# 8. Camera Check
log_info "Checking for connected cameras..."
CAMERA_LIST=$(tcam-ctrl -l)

if [[ -z "$CAMERA_LIST" ]]; then
    echo ""
    log_err "NO CAMERAS DETECTED!"
    log_warn "The drivers were just installed. A reboot is usually required to load the kernel modules."
    log_warn "Rebooting in 5 seconds..."
    for i in 5 4 3 2 1; do
        echo -n "$i... "
        sleep 1
    done
    echo ""
    sudo reboot
    exit 0
fi

log_info "Camera detected!"
echo "$CAMERA_LIST"

# 9. Generate Device State JSON
log_info "Generating Camera Configuration (devicestate.json)..."

# Check if generate_config.sh exists, if not, create it
if [ ! -f "generate_config.sh" ]; then
    log_warn "generate_config.sh not found in repo. Creating it now..."
    cat << 'EOF' > generate_config.sh
#!/bin/bash
OUTPUT_FILE="devicestate.json"
CAM_INFO=$(tcam-ctrl -l | head -n 1)
SERIAL=$(echo "$CAM_INFO" | grep -oP 'Serial: \K\d+')
echo "Found Camera: $SERIAL"

# Defaults
WIDTH=640
HEIGHT=480
FPS="30/1"

echo "Reading properties..."
PROPERTIES=$(tcam-ctrl --save-json "$SERIAL")

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
echo "Configuration saved."
EOF
    chmod +x generate_config.sh
fi

# Run the generation script
./generate_config.sh

# 10. Systemd Service Setup
echo ""
log_info "ALL DONE!"
read -p "Do you want to create a Systemd Service to auto-start this app? (y/N) " svc_choice

if [[ "$svc_choice" == "y" || "$svc_choice" == "Y" ]]; then
    SERVICE_NAME="laser_profiler"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    USER_NAME=$(whoami)
    PYTHON_EXEC="$PROJECT_ROOT/.env/bin/python"
    MAIN_SCRIPT="$PROJECT_ROOT/main.py"

    log_info "Creating service file at $SERVICE_FILE..."

    sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Laser Beam Profiler Service
After=network.target multi-user.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$PROJECT_ROOT
ExecStart=$PYTHON_EXEC $MAIN_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    log_info "Service created."

    read -p "Enable and Start the service now? (y/N) " start_choice
    if [[ "$start_choice" == "y" || "$start_choice" == "Y" ]]; then
        sudo systemctl enable $SERVICE_NAME
        sudo systemctl start $SERVICE_NAME
        log_info "Service STARTED. Check status with: systemctl status $SERVICE_NAME"
    else
        log_info "Service created but NOT started."
    fi
fi

log_info "Script Finished Successfully."