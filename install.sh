#!/bin/bash

# ==============================================================================
#  Laser Profiler Setup Script (Automated Production + Local Dev Version)
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

    # --- THE HUB CHECK ---
    read -p "Enter the Central Pi 5 IP [LEAVE BLANK FOR LOCAL TEST]: " CENTRAL_IP
    if [ -z "$CENTRAL_IP" ]; then
        log_warn "NO HUB IP PROVIDED. Entering Local-Only Mode."
        SKIP_HUB=true
    else
        log_info "Hub IP set to $CENTRAL_IP. Enabling Network Mode."
        SKIP_HUB=false
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
        python3-libgpiod libopenblas-dev sshpass openssl

    # --- NETWORK REGISTRATION (Only if CENTRAL_IP provided) ---
    if [ "$SKIP_HUB" = false ]; then
        log_info "Configuring Rathole Client..."
        wget -qO /tmp/rathole.zip https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-arm-unknown-linux-musleabihf.zip
        unzip -o /tmp/rathole.zip -d /tmp/
        sudo mv /tmp/rathole /usr/local/bin/rathole
        sudo chmod +x /usr/local/bin/rathole

        CURRENT_HOSTNAME=$(hostname)
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

        log_info "Creating Rathole Service..."
        sudo bash -c "cat > /etc/systemd/system/rathole.service" <<EOL
[Unit]
Description=Rathole Reverse Tunnel Client
After=network.target
[Service]
Type=simple
User=$USER_NAME
ExecStart=/usr/local/bin/rathole --client /etc/rathole/client.toml
Restart=always
[Install]
WantedBy=multi-user.target
EOL
        sudo systemctl daemon-reload
        sudo systemctl enable rathole --now

        log_info "Injecting Config to Hub ($CENTRAL_IP)..."
        sshpass -p 'raspberry' ssh -o StrictHostKeyChecking=no pi@$CENTRAL_IP << EOF_SSH
            cd /home/pi/rathole
            echo "[server.services.$CURRENT_HOSTNAME]" >> rathole-server.toml
            echo "token = \"$TOKEN\"" >> rathole-server.toml
            echo "bind_addr = \"0.0.0.0:$REMOTE_PORT\"" >> rathole-server.toml
            
            cat > dynamic/$CURRENT_HOSTNAME.yml << EOL_YAML
http:
  routers:
    $CURRENT_HOSTNAME-router:
      rule: 'PathPrefix("/$CURRENT_HOSTNAME")'
      service: "$CURRENT_HOSTNAME-service"
      middlewares: ["strip-$CURRENT_HOSTNAME"]
  middlewares:
    strip-$CURRENT_HOSTNAME:
      stripPrefix: { prefixes: ["/$CURRENT_HOSTNAME"] }
  services:
    $CURRENT_HOSTNAME-service:
      loadBalancer: { servers: [{ url: "http://rathole:$REMOTE_PORT" }] }
EOL_YAML
            docker compose restart rathole traefik
EOF_SSH
    else
        log_warn "Skipping Network Registration. Use http://$(hostname).local:5000 for local testing."
    fi

    log_info "Installing TIS Camera Drivers..."
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    wget -O tiscamera.deb "https://dl.theimagingsource.com/7366c5ab-631a-5e7a-85f4-decf5ae86a07/"
    wget -O tcamprop.deb "https://dl.theimagingsource.com/72ff2659-344d-57c8-b96b-4540afc4b629/"
    sudo apt-get install -y ./tiscamera.deb ./tcamprop.deb

    log_info "Installing GStreamer & Python Science Stack..."
    sudo apt-get install -y \
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
pip install gunicorn flask flask-cors adafruit-circuitpython-tmp117 RPi.GPIO

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
