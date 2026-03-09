#!/bin/bash

# ==============================================================================
#  Laser Profiler Setup Script (Automated Production Version)
# ==============================================================================

# Ensure standard PATH is available during cron re-runs
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# Helper function for colored output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

# Context Variables
STATE_FILE="$HOME/.laser_setup_state"
SCRIPT_PATH=$(readlink -f "$0")
INSTALL_DIR="$HOME/code"
USER_NAME=$(whoami)

# Determine current state (0 = Initial, 1 = First Reboot, 2 = Second Reboot)
if [ -f "$STATE_FILE" ]; then
    STATE=$(cat "$STATE_FILE")
else
    STATE="0"
fi

# ==============================================================================
# PHASE 1: Initial System Preparation & Driver Installation
# ==============================================================================
if [ "$STATE" == "0" ]; then
    log_info "Starting Phase 1: Initial Setup"
    
    # 0. Prompts (Only user interaction)
    echo ""
    read -p "Enter a local hostname for this Raspberry Pi (e.g., dazzler-picam-0): " NEW_HOSTNAME
    if [ -n "$NEW_HOSTNAME" ]; then
        log_info "Setting hostname to $NEW_HOSTNAME..."
        sudo hostnamectl set-hostname "$NEW_HOSTNAME"
        sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
    fi

    read -p "Enter the IP address of the Central Pi 5 (Hub): " CENTRAL_IP

    # 1. OS Check (Debian 11 / Bullseye)
    log_info "Checking OS version..."
    if grep -q "bullseye" /etc/os-release; then
        log_info "OS is Debian 11 (Bullseye). Proceeding..."
    else
        log_err "Detected OS is NOT Debian 11 (Bullseye). This script is optimized for Bullseye. Aborting."
        exit 1
    fi

    # 2. Update and Upgrade
    log_info "Updating system packages..."
    sudo apt-get update && sudo apt-get -y upgrade

    # 3. I2C Configuration
    log_info "Configuring I2C Interface..."
    sudo raspi-config nonint do_i2c 0

    CONFIG_FILE="/boot/config.txt"
    BACKUP_FILE="/boot/config.txt.bak"

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
    # Note: Added sshpass here for the automated Pi 5 connection
    sudo apt-get install -y \
        git python3-pip python3-venv python3-dev \
        wget curl jq unzip i2c-tools libgpiod-dev \
        python3-libgpiod libopenblas-dev sshpass

    # 5. Rathole Tunnel Configuration & Registration
    log_info "Downloading Rathole Client..."
    wget -qO /tmp/rathole.zip https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-arm-unknown-linux-musleabihf.zip
    unzip -o /tmp/rathole.zip -d /tmp/
    sudo mv /tmp/rathole /usr/local/bin/rathole
    sudo chmod +x /usr/local/bin/rathole

    log_info "Generating Rathole Config..."
    
    # [FIX 1] Grab the actual system hostname to guarantee it is never blank
    CURRENT_HOSTNAME=$(hostname)
    
    # Generate a random hex token and a random port between 50000 and 60000
    TOKEN=$(openssl rand -hex 16)
    REMOTE_PORT=$(( 50000 + RANDOM % 10000 ))

    sudo mkdir -p /etc/rathole
    sudo bash -c "cat > /etc/rathole/client.toml" <<EOL
[client]
remote_addr = "$CENTRAL_IP:2333"

[client.services.$CURRENT_HOSTNAME]
token = "$TOKEN"
local_addr = "127.0.0.1:5000"
EOL

    log_info "Creating Rathole Systemd Service..."
    sudo bash -c "cat > /etc/systemd/system/rathole.service" <<EOL
[Unit]
Description=Rathole Reverse Tunnel Client
After=network.target

[Service]
Type=simple
User=$USER_NAME
ExecStart=/usr/local/bin/rathole --client /etc/rathole/client.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable rathole --now

    log_info "Registering Camera with Central Pi 5 ($CENTRAL_IP)..."
    
        # [FIX] Safer SSH injection using independent files
    sshpass -p 'raspberry' ssh -o StrictHostKeyChecking=no pi@$CENTRAL_IP << EOF_SSH
    cd /home/pi/rathole

    # 1. Safely append to the Rathole Server Config
    cat >> rathole-server.toml << EOL_TOML

[server.services.$CURRENT_HOSTNAME]
token = "$TOKEN"
bind_addr = "0.0.0.0:$REMOTE_PORT"
EOL_TOML

    # 2. Create an independent Traefik config file for this specific camera!
    cat > dynamic/$CURRENT_HOSTNAME.yml << EOL_YAML
http:
  middlewares:
    strip-$CURRENT_HOSTNAME:
      stripPrefix:
        prefixes:
          - "/$CURRENT_HOSTNAME"
  routers:
    $CURRENT_HOSTNAME-router:
      rule: 'PathPrefix("/$CURRENT_HOSTNAME")'
      service: "$CURRENT_HOSTNAME-service"
      middlewares:
        - "strip-$CURRENT_HOSTNAME"
  services:
    $CURRENT_HOSTNAME-service:
      loadBalancer:
        servers:
          - url: "http://rathole:$REMOTE_PORT"
EOL_YAML

	  if ! grep -q "\"/$CURRENT_HOSTNAME\"" www/index.html; then
        sed -i "//a \\        <a href=\"/$CURRENT_HOSTNAME\" class=\"card\">📷 $CURRENT_HOSTNAME</a>" www/index.html
    fi

    # Restart the Hub to apply changes
    docker compose restart rathole traefik
EOF_SSH

    log_info "Central Hub successfully updated and restarted!"

    # 6. Install The Imaging Source Drivers
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

    # 7. Install GStreamer & Python Science Stack
    log_info "Installing GStreamer, OpenCV, Scipy..."
    sudo apt-get install -y \
        libgstreamer1.0-0 gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly gstreamer1.0-libav \
        gstreamer1.0-tools libcairo2-dev libgirepository1.0-dev \
        pkg-config python3-opencv python3-scipy \
        python3-gst-1.0 python3-gi

    # Setup automated resume via crontab
    log_info "Setting up auto-resume for after reboot..."
    (crontab -l 2>/dev/null; echo "@reboot sleep 15 && /bin/bash \"$SCRIPT_PATH\" >> \"$HOME/laser_install_resume.log\" 2>&1") | crontab -

    echo "1" > "$STATE_FILE"
    log_info "Phase 1 Complete. Rebooting in 5 seconds to load kernel modules..."
    sleep 5
    sudo reboot
    exit 0
fi

# ==============================================================================
# PHASE 2: Camera Detection Loop
# ==============================================================================
if [ "$STATE" == "1" ] || [ "$STATE" == "2" ]; then
    log_info "Resuming Installation (Attempt $STATE after reboot)..."
    log_info "Checking for connected cameras..."
    CAMERA_LIST=$(tcam-ctrl -l)

    if [[ -z "$CAMERA_LIST" ]]; then
        if [ "$STATE" == "1" ]; then
            log_warn "Camera NOT detected. Trying one more reboot just in case..."
            echo "2" > "$STATE_FILE"
            sudo reboot
            exit 0
        else
            log_err "Camera still NOT detected after second reboot. Aborting auto-setup."
            echo "$(date): ERROR: Camera not detected after multiple reboots. Please check physical USB/GigE connections and driver compatibility." > "$HOME/camera_error.log"
            
            # Clean up the crontab and state so it doesn't run again forever
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
            rm -f "$STATE_FILE"
            exit 1
        fi
    else
        log_info "Camera successfully detected!"
        echo "$CAMERA_LIST"
        
        # Clean up the crontab and state file to break the loop
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
        rm -f "$STATE_FILE"
    fi
fi

# ==============================================================================
# PHASE 3: Application & Service Setup
# ==============================================================================
log_info "Starting Phase 3: Application Setup"

# 8. Clone Repository
REPO_URL="https://github.com/LucaSain/CameraControlSystem.git"
REPO_NAME=$(basename "$REPO_URL" .git)

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
fi

cd "$INSTALL_DIR" || exit

if [ -d "$REPO_NAME" ]; then
    log_warn "Directory $REPO_NAME already exists. Pulling latest changes..."
    cd "$REPO_NAME" || exit
    git pull
else
    log_info "Cloning repository to $INSTALL_DIR..."
    git clone "$REPO_URL"
    cd "$REPO_NAME" || exit
fi

PROJECT_ROOT=$(pwd)

# 9. Python Virtual Environment (.env)
log_info "Setting up Python Virtual Environment..."

# Create env accessing system packages (OpenCV, GObject)
python3 -m venv .env --system-site-packages
source .env/bin/activate

log_info "Cleaning environment of conflicts..."
python3 -m pip install --upgrade pip setuptools wheel
pip uninstall -y numpy opencv-python opencv-python-headless

log_info "Installing Python Libraries (Gunicorn, Flask, Hardware)..."
pip install "numpy<2.0.0"
pip install gunicorn flask flask-cors adafruit-circuitpython-tmp117 adafruit-blinka RPi.GPIO

# 10. Create Data Directory (/opt)
log_info "Configuring Data Directory (/opt/thermal_cam)..."
sudo mkdir -p /opt/thermal_cam
sudo chown -R "$USER_NAME:$USER_NAME" /opt/thermal_cam
sudo chmod -R 775 /opt/thermal_cam

# 11. Device Configuration
log_info "Generating Camera Config (devicestate.json)..."
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

# 12. Systemd Service Setup (Automatic)
SERVICE_NAME="laser_profiler"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GUNICORN_EXEC="$PROJECT_ROOT/.env/bin/gunicorn"

log_info "Creating and enabling systemd service at $SERVICE_FILE..."

sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Laser Beam Profiler Service
After=network.target multi-user.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$PROJECT_ROOT

# Apply 32-bit Architecture Paths for Tcam driver
# Environment="GI_TYPELIB_PATH=/usr/lib/arm-linux-gnueabihf/girepository-1.0:/usr/lib/girepository-1.0"
# Environment="GST_PLUGIN_PATH=/usr/lib/arm-linux-gnueabihf/gstreamer-1.0:/usr/lib/gstreamer-1.0"

# Production Gunicorn Command
ExecStart=$GUNICORN_EXEC --worker-class gthread --workers 1 --threads 10 --bind 0.0.0.0:5000 --timeout 60 main:app

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl start $SERVICE_NAME

log_info "Service $SERVICE_NAME STARTED automatically."
log_info "Installation and configuration are 100% COMPLETE!"
