#!/bin/bash

# ==============================================================================
#  Laser Profiler Setup Script (Updated for Production)
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

# 3. I2C Configuration
log_info "Configuring I2C Interface..."
# Enable I2C via raspi-config first (ensures kernel modules are loaded)
sudo raspi-config nonint do_i2c 0

CONFIG_FILE="/boot/config.txt"
BACKUP_FILE="/boot/config.txt.bak"

# Check if baudrate is already set
if grep -q "i2c_arm_baudrate" "$CONFIG_FILE"; then
    log_warn "I2C Baudrate is already manually configured. Skipping modification."
else
    log_info "Setting I2C Baudrate to 10kHz (Safe for long cables)..."
    sudo cp "$CONFIG_FILE" "$BACKUP_FILE"
    sudo sed -i 's/dtparam=i2c_arm=on/dtparam=i2c_arm=on,i2c_arm_baudrate=10000/' "$CONFIG_FILE"
    log_info "I2C Speed set to 10000. Backup saved."
fi

# 4. Install Dependencies
log_info "Installing Git, Python3, I2C tools, and System libraries..."
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

URL1="https://dl.theimagingsource.com/7366c5ab-631a-5e7a-85f4-decf5ae86a07/"
URL2="https://dl.theimagingsource.com/72ff2659-344d-57c8-b96b-4540afc4b629/"
URL3="https://dl.theimagingsource.com/f32194fe-7faa-50e3-94c4-85c504dbdea6/" 

wget -O tiscamera.deb "$URL1"
wget -O tcamprop.deb "$URL2"
wget -O gigetool.deb "$URL3"

log_info "Installing Drivers..."
sudo apt-get install -y ./tiscamera.deb ./tcamprop.deb ./gigetool.deb

# 6. Install GStreamer & Python Science Stack
log_info "Installing GStreamer, OpenCV, Scipy..."
sudo apt-get install -y \
    libgstreamer1.0-0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-tools \
    libcairo2-dev \
    libgirepository1.0-dev \
    pkg-config \
    python3-opencv \
    python3-scipy \
    python3-gst-1.0 \
    python3-gi

# 7. Clone Repository
echo ""
read -p "Enter installation directory (default: ~/code): " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-"$HOME/code"}

REPO_URL="https://github.com/LucaSain/CameraControlSystem.git"

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

# 8. Python Virtual Environment (.env)
log_info "Setting up Python Virtual Environment..."

# Create env accessing system packages (OpenCV, GObject)
python3 -m venv .env --system-site-packages
source .env/bin/activate

log_info "Cleaning environment of conflicts..."
pip uninstall -y numpy opencv-python opencv-python-headless

log_info "Installing Python Libraries (Gunicorn, Flask, Hardware)..."
# Force Numpy 1.x for compatibility
pip install "numpy<2.0.0"

# Install Production Server and App Dependencies
pip install \
    gunicorn \
    flask \
    flask-cors \
    adafruit-circuitpython-tmp117 \
    adafruit-blinka \
    RPi.GPIO

# 9. Create Data Directory (/opt)
log_info "Configuring Data Directory (/opt/thermal_cam)..."
# Create the directory if it doesn't exist
sudo mkdir -p /opt/thermal_cam

# Grant ownership to the current user (usually pi) so the DB doesn't lock
USER_NAME=$(whoami)
sudo chown -R $USER_NAME:$USER_NAME /opt/thermal_cam
sudo chmod -R 775 /opt/thermal_cam

log_info "Permissions granted for $USER_NAME at /opt/thermal_cam"

# 10. Device Configuration
log_info "Checking for connected cameras..."
CAMERA_LIST=$(tcam-ctrl -l)

if [[ -z "$CAMERA_LIST" ]]; then
    log_err "NO CAMERAS DETECTED!"
    log_warn "If drivers were just installed, a reboot is required."
    # We don't exit here to allow setting up the service even if cam is unplugged
else
    echo "$CAMERA_LIST"
fi

log_info "Generating Camera Config..."
cat << 'EOF' > generate_config.sh
#!/bin/bash
OUTPUT_FILE="devicestate.json"
TRIGGER_MODE=${1:-"Off"} 

CAM_INFO=$(tcam-ctrl -l | head -n 1)
SERIAL=$(echo "$CAM_INFO" | grep -oP 'Serial: \K\d+')

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
EOF
chmod +x generate_config.sh
./generate_config.sh "Off" # Default to Continuous

# 11. Systemd Service Setup (Production Gunicorn)
echo ""
read -p "Create Systemd Service? (y/N) " svc_choice

if [[ "$svc_choice" == "y" || "$svc_choice" == "Y" ]]; then
    SERVICE_NAME="laser_profiler"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    
    # Path to Gunicorn inside the venv
    GUNICORN_EXEC="$PROJECT_ROOT/.env/bin/gunicorn"
    
    log_info "Creating service file at $SERVICE_FILE..."

    sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Laser Beam Profiler Service
After=network.target multi-user.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$PROJECT_ROOT

# Production Gunicorn Command:
# - gthread worker class: Handles threads for I/O bound tasks
# - workers 1: Single process to hold the Camera Lock
# - threads 10: Allows 10 concurrent connections (streams + api)
# - bind 0.0.0.0: Listen on all interfaces
ExecStart=$GUNICORN_EXEC --worker-class gthread --workers 1 --threads 10 --bind 0.0.0.0:5000 --timeout 60 main:app

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
        log_info "Service STARTED."
    fi
fi

log_info "Installation Complete!"