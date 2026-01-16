# 📸 Laser Beam Profiler & Camera Control System

A high-performance Python application for **The Imaging Source (TIS)** cameras on Raspberry Pi. This system provides a low-latency MJPEG video stream, real-time Laser Beam Profiling (Gaussian Fit), and synchronous data logging of centroids and temperature sensors.

## 🚀 Quick Install

Set up the entire system (dependencies, drivers, repo cloning, and systemd service) with a single command:

```bash
bash <(curl -s https://raw.githubusercontent.com/LucaSain/CameraControlSystem/refs/heads/main/install.sh)
```

**What this script does:**
1. Checks for Debian 11 (Bullseye).
2. Installs system dependencies (GStreamer, OpenCV, Python environment).
3. Downloads and installs TIS Camera Drivers.
4. Clones this repository and sets up a virtual environment.
5. Auto-configures the connected camera.
6. Sets up a `systemd` service to run the profiler on boot.

---

## ✨ Features

* **Real-time Gaussian Fitting:** Uses 2D Gaussian mathematics (with optimized 1D/2D switching) to find the sub-pixel center of a laser beam.
* **Non-Blocking Architecture:** Uses a Producer-Consumer threading model. The video stream never stutters, even if mathematical analysis or disk I/O is heavy.
* **Web Stream:** Live MJPEG stream accessible via browser (`http://<pi-ip>:5000/mjpeg_stream`).
* **Data Logging:** Logs Timestamp, Centroid (X,Y), and Temperature Sensor data to CSV in the background.
* **Hardware Integration:** Supports `adafruit_tmp117` I2C temperature sensors.

## 🛠️ Hardware Requirements

* **Raspberry Pi 4 / 5** (Quad Core recommended for 2D fitting).
* **OS:** Raspberry Pi OS Legacy (Bullseye) / Debian 11.
* **Camera:** The Imaging Source (TIS) GigE or USB Camera.
* **Sensors:** up to 4x TMP117 High-Precision Temperature Sensors (I2C).

## 📂 Project Structure

```text
.
├── main.py              # Application Entry Point
├── TIS.py               # TIS Camera Wrapper Class
├── generate_config.sh   # Helper to capture camera properties
├── devicestate.json     # Auto-generated camera configuration
├── install.sh           # One-line installer script
├── requirements.txt     # Python dependencies
└── .gitignore           # Git ignore rules
```

## 🚦 Usage
**Manage the Service**
If you enabled the systemd service during installation:
```bash
# Start
sudo systemctl start laser_profiler

# Stop
sudo systemctl stop laser_profiler

# View Logs (Real-time)
journalctl -u laser_profiler -f
```

## Access the Stream

Open your web browser and navigate to: ```http://<YOUR_RASPBERRY_PI_IP>:5000```

