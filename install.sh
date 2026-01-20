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

# 3. Enable Hardware Interfaces (I2C)
log_info "Enabling I2C Interface..."
sudo raspi-config nonint do_i2c 0

# 4. Install Core Dependencies & Hardware Tools
log_info "Installing Git, Python3, I2C tools, and System dependencies..."
# Added: libopenblas-dev (Critical for NumPy on ARM)
sudo apt-get install -y \
    git \
    python3-pip \
    python3-venv \
    python3-dev \
    wget \
    curl \
    jq \
    unzip \
    i2c-tools \
    libgpiod-dev \
    python3-libgpiod \
    libopenblas-dev

# 5. Install The Imaging Source Drivers
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
log_info "Downloading TIS Camera Drivers..."

URL1="https://dl.theimagingsource.com/7366c5ab-631a-5e7a-85f4-decf5ae86a07/tiscamera_1.1.0.4137_armhf.deb/"
URL2="https://dl.theimagingsource.com/72ff2659-344d-57c8-b96b-4540afc4b629/tiscamera-tcamprop_1.0.0.4137_armhf.deb/"
URL3="https://dl.theimagingsource.com/f32194fe-7faa-50e3-94c4-85c504dbdea6/tcam-gigetool_0.3.0_armhf.deb/" 

wget -O tiscamera.deb "$URL1"
wget -O tcamprop.deb "$URL2"
wget -O gigetool.deb "$URL3"

log_info "Installing Drivers..."
sudo apt-get install -y ./tiscamera.deb ./tcamprop.deb ./gigetool.deb

# 6. Install GStreamer, Build Tools & Python Science Stack
log_info "Installing GStreamer, OpenCV, Scipy and Build Tools..."
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
    gstreamer1.0-pulseaudio \
    libcairo2-dev \
    libgirepository1.0-dev \
    pkg-config \
    python3-opencv \
    python3-scipy \
    python3-gst-1.0 \
    python3-gi

# 7. Clone Github Repo
echo ""
read -p "Enter installation directory (default: ~/code): " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-"$HOME/code"}

REPO_URL="https://github.com/LucaSain/CameraControlSystem.git"
log_info "Using default Repo URL: $REPO_URL"

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

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

# 8. Create Virtual Environment (.env) & Install Requirements
log_info "Setting up Python Virtual Environment in .env..."
python3 -m venv .env --system-site-packages
source .env/bin/activate

log_info "Installing Adafruit Blinka..."
pip3 install --upgrade adafruit-blinka

if [ -f "requirements.txt" ]; then
    log_info "Installing requirements.txt..."
    pip install --upgrade pip
    # FIX: Force install stable numpy 1.x BEFORE other requirements
    pip install "numpy<2.0.0"
    pip install -r requirements.txt
else
    log_warn "requirements.txt not found! Installing default dependencies manually..."
    # FIX: Explicitly pin numpy<2.0.0 here as well
    pip install "numpy<2.0.0" flask adafruit-circuitpython-tmp117 adafruit-blinka RPi.GPIO
fi

# 9. Camera Check
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

# 10. Generate Device State JSON
echo ""
log_info "Configuring Camera Settings..."

read -p "Do you want to enable Hardware Trigger Mode? (y/N) " trig_choice
if [[ "$trig_choice" == "y" || "$trig_choice" == "Y" ]]; then
    TRIGGER_VAL="On"
    log_info ">> Trigger Mode: ENABLED"
else
    TRIGGER_VAL="Off"
    log_info ">> Trigger Mode: DISABLED (Continuous)"
fi

log_info "Creating configuration generator script..."
cat << 'EOF' > generate_config.sh
#!/bin/bash
OUTPUT_FILE="devicestate.json"
TRIGGER_MODE=${1:-"Off"} 

CAM_INFO=$(tcam-ctrl -l | head -n 1)
SERIAL=$(echo "$CAM_INFO" | grep -oP 'Serial: \K\d+')
echo "Found Camera: $SERIAL"
echo "Applying Trigger Mode: $TRIGGER_MODE"

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
  --arg trig "$TRIGGER_MODE" \
  --argjson props "$PROPERTIES" \
  '{
    pipeline: $pipe,
    serial: ($serial | tonumber),
    height: $h,
    width: $w,
    framerate: $fps,
    properties: ($props + { "TriggerMode": $trig })
  }' > "$OUTPUT_FILE"

echo "Configuration saved to $OUTPUT_FILE"
EOF

chmod +x generate_config.sh
./generate_config.sh "$TRIGGER_VAL"


# 11. Systemd Service Setup
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
