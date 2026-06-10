#!/bin/bash

# ==============================================================================
#  Laser Profiler Setup Script (Local Dev Version)
# ==============================================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

STATE_FILE="$HOME/.laser_setup_state"
SCRIPT_PATH=$(readlink -f "$0")
INSTALL_DIR="$HOME/code"
USER_NAME=$(whoami)

if [ -f "$STATE_FILE" ]; then
    STATE=$(cat "$STATE_FILE")
else
    STATE="0"
fi

# ==============================================================================
# PHASE 1: Initial System Preparation
# ==============================================================================
if [ "$STATE" == "0" ]; then
    log_info "Starting Phase 1: Initial Setup"

    echo ""
    read -p "Enter a local hostname (e.g., dazzler-picam-0): " NEW_HOSTNAME
    if [ -n "$NEW_HOSTNAME" ]; then
        log_info "Setting hostname to $NEW_HOSTNAME..."
        sudo hostnamectl set-hostname "$NEW_HOSTNAME"
        sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
    fi

    log_info "Checking OS version..."
    if ! grep -q "bullseye" /etc/os-release; then
        log_err "Detected OS is NOT Debian 11 (Bullseye). Aborting."
        exit 1
    fi

    log_info "Updating system packages..."
    sudo apt-get update && sudo apt-get -y upgrade

    log_info "Configuring I2C Interface (10kHz safe mode)..."
    sudo raspi-config nonint do_i2c 0
    if ! grep -q "i2c_arm_baudrate" /boot/config.txt; then
        sudo sed -i 's/dtparam=i2c_arm=on/dtparam=i2c_arm=on,i2c_arm_baudrate=10000/' /boot/config.txt
    fi

    log_info "Installing Dependencies..."
    sudo apt-get install -y \
        git python3-pip python3-venv python3-dev \
        wget curl jq unzip i2c-tools libgpiod-dev \
        python3-libgpiod libopenblas-dev openssl

    log_info "Setting up persistent sensor database location..."
    sudo mkdir -p /opt/thermal_cam
    sudo touch /opt/thermal_cam/sensor_data.db
    # Owned by the running user, readable by everyone
    sudo chown "$USER_NAME":"$USER_NAME" /opt/thermal_cam/sensor_data.db
    sudo chmod 644 /opt/thermal_cam/sensor_data.db

    log_info "Installing TIS Camera Drivers..."
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    wget -O tiscamera.deb "https://dl.theimagingsource.com/7366c5ab-631a-5e7a-85f4-decf5ae86a07/"
    wget -O tcamprop.deb "https://dl.theimagingsource.com/72ff2659-344d-57c8-b96b-4540afc4b629/"
    wget -O tcampimipisrc.deb "https://dl.theimagingsource.com/f32194fe-7faa-50e3-94c4-85c504dbdea6/"
    sudo apt-get install -y ./tiscamera.deb ./tcamprop.deb ./tcampimipisrc.deb

    log_info "Installing GStreamer & Python Science Stack..."
    sudo apt-get install -y \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad gstreamer1.0-libav \
        python3-opencv python3-scipy python3-gst-1.0 python3-gi

    (crontab -l 2>/dev/null; echo "@reboot sleep 15 && /bin/bash \"$SCRIPT_PATH\" >> \"$HOME/laser_install_resume.log\" 2>&1") | crontab -
    echo "1" > "$STATE_FILE"
    log_info "Phase 1 Complete. Rebooting..."
    sleep 3 && sudo reboot
    exit 0
fi

# ==============================================================================
# PHASE 2: Camera Detection & Application Setup
# ==============================================================================
log_info "Checking for Camera..."
if [[ -z $(tcam-ctrl -l) ]]; then
    log_err "Camera not detected. Check connections."
    exit 1
fi

log_info "Setting up Application..."
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
git clone "https://github.com/LucaSain/CameraControlSystem.git"
cd CameraControlSystem

python3 -m venv .env --system-site-packages
source .env/bin/activate

# --- Dependency fixes ---
# The Bullseye-bundled pip ships an ancient toml parser that crashes
# (IndexError) on modern pyproject.toml files, which then cascades into
# resolver failures (e.g. markupsafe). Upgrade the build toolchain first.
log_info "Upgrading pip/setuptools/wheel before installing dependencies..."
pip install --upgrade pip setuptools wheel

log_info "Installing Python application dependencies..."
pip install gunicorn flask flask-cors adafruit-circuitpython-tmp117 RPi.GPIO

log_info "Generating camera configuration (devicestate.json)..."
chmod +x ./generate_config.sh
# Run with the GStreamer plugin path exported so the TIS MIPI elements
# (tcampimipisrc, etc.) are found during config generation.
export GST_PLUGIN_PATH=/usr/lib/arm-linux-gnueabihf/gstreamer-1.0
if ! ./generate_config.sh; then
    log_err "generate_config.sh failed. Camera config was not created. Aborting."
    exit 1
fi

if [ ! -f "devicestate.json" ]; then
    log_err "devicestate.json was not produced by generate_config.sh. Aborting."
    exit 1
fi

log_info "Creating Laser Profiler Service..."
sudo bash -c "cat > /etc/systemd/system/laser_profiler.service" <<EOL
[Unit]
Description=Laser Beam Profiler
After=network.target
[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$(pwd)
Environment="GST_PLUGIN_PATH=/usr/lib/arm-linux-gnueabihf/gstreamer-1.0"
ExecStart=$(pwd)/.env/bin/gunicorn --worker-class gthread --workers 1 --threads 10 --bind 0.0.0.0:5000 main:app
Restart=always
[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable laser_profiler --now
rm -f "$STATE_FILE"
crontab -l | grep -v "$SCRIPT_PATH" | crontab -

log_info "INSTALLATION COMPLETE. Local access: http://$(hostname).local:5000"
