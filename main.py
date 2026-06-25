from datetime import datetime
import json
import time
import logging
import sys
import threading
import queue
import sqlite3
import io
import os
import signal
import atexit

# --- LOGGING SETUP (configure before the optional hardware imports so their
#     warnings are captured) ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

import TIS
import cv2
import numpy as np
from flask import Flask, Response, request, jsonify, stream_with_context, render_template
from scipy.optimize import curve_fit
from flask_cors import CORS
from werkzeug.middleware.proxy_fix import ProxyFix

# --- OPTIONAL TEMPERATURE-SENSOR IMPORTS ---
# These depend on Blinka / I2C hardware being present. If anything is missing
# the app must still run (camera is the primary function), so the imports are
# guarded and temperature sensing simply becomes unavailable.
try:
    import board
except Exception as e:  # ImportError, NotImplementedError (no platform), etc.
    board = None
    logging.warning(f"'board' import failed - temperature sensing disabled: {e}")

try:
    from adafruit_tmp117 import TMP117
except Exception as e:
    TMP117 = None
    logging.warning(f"'adafruit_tmp117' import failed - temperature sensing disabled: {e}")

app = Flask(__name__)
CORS(app)

# --- PROXY FIX ---
# Trust Traefik headers to handle relative paths properly
app.wsgi_app = ProxyFix(app.wsgi_app, x_prefix=1)

# --- Configuration ---
DB_NAME = "/opt/thermal_cam/sensor_data.db"
DEVICE_STATE_FILE = "devicestate.json"

# Fixed address order -> column order (temp1..temp4). Missing sensors are
# recorded as NULL so the column mapping stays stable regardless of which
# sensors are present.
TMP117_ADDRESSES = [0x48, 0x49, 0x4A, 0x4B]

# --- Queues & Sync ---
processing_queue = queue.Queue(maxsize=10)   # Math/Analysis (Gaussian Fit)
write_queue = queue.Queue()                  # Database Writes
encode_queue = queue.Queue(maxsize=5)        # Video Encoding (Visualization)

stop_event = threading.Event()

# --- Global Variables & Sync ---
cX, cY = None, None
frame_id = 0
frame_condition = threading.Condition()  # Broadcasts new frames to clients
global_jpeg_bytes = None
IS_TRIGGER_MODE = False
Tis = None

i2c = None
temp_sensors = {}  # address -> TMP117 instance (only successfully-detected ones)


# --- DATABASE HELPER ---
def get_db_connection():
    conn = sqlite3.connect(DB_NAME, timeout=30.0)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    return conn


def init_db():
    with get_db_connection() as conn:
        cursor = conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS measurements (
                timestamp DATETIME PRIMARY KEY,
                cx REAL,
                cy REAL,
                temp1 REAL,
                temp2 REAL,
                temp3 REAL,
                temp4 REAL
            )
        ''')
        conn.commit()


init_db()


# --- TEMPERATURE SENSORS (fully optional) ---
def init_temp_sensors():
    """
    Probe each TMP117 address independently. Any combination of 0..4 sensors
    being present is fine; failures never raise. Safe to leave the app running
    with no sensors at all.
    """
    global i2c, temp_sensors
    temp_sensors = {}

    if board is None or TMP117 is None:
        logging.warning("Temperature libraries unavailable; running without temperature sensors.")
        return

    try:
        i2c = board.I2C()
    except Exception as e:
        logging.error(f"I2C bus init failed; running without temperature sensors: {e}")
        i2c = None
        return

    for addr in TMP117_ADDRESSES:
        try:
            sensor = TMP117(i2c, address=addr)
            # Touch it once to confirm it really responds.
            _ = sensor.temperature
            temp_sensors[addr] = sensor
            logging.info(f"TMP117 detected at 0x{addr:02X}")
        except Exception as e:
            logging.warning(f"No usable TMP117 at 0x{addr:02X}: {e}")

    if not temp_sensors:
        logging.warning("No temperature sensors detected; continuing without them.")
    else:
        logging.info(f"{len(temp_sensors)} temperature sensor(s) active.")


def read_temperatures():
    """
    Always returns exactly 4 values (temp1..temp4), each a float or None.
    A read that fails mid-run yields None for that channel instead of crashing
    the analysis loop or stalling the camera callback.
    """
    out = []
    for addr in TMP117_ADDRESSES:
        sensor = temp_sensors.get(addr)
        if sensor is None:
            out.append(None)
            continue
        try:
            out.append(float(sensor.temperature))
        except Exception as e:
            logging.debug(f"TMP117 read failed at 0x{addr:02X}: {e}")
            out.append(None)
    return out


init_temp_sensors()


# --- CAMERA STARTUP ---
def get_startup_mode():
    try:
        if os.path.exists(DEVICE_STATE_FILE):
            with open(DEVICE_STATE_FILE, 'r') as f:
                data = json.load(f)
                props = data.get('properties', {})
                val = props.get('TriggerMode', props.get('Trigger Mode', 'Off'))
                return val == 'On'
    except Exception as e:
        logging.error(f"Config Read Error: {e}")
    return False


try:
    Tis = TIS.TIS()
    logging.info("Loading camera...")
    Tis.loadstatefile(DEVICE_STATE_FILE)
    Tis.Start_pipeline()
    IS_TRIGGER_MODE = get_startup_mode()
    logging.info(f"Startup Mode: {'Trigger' if IS_TRIGGER_MODE else 'Continuous'}")
except Exception as error:
    logging.error(f"Camera Error: {error}")


# --- ROBUST SHUTDOWN / CAMERA RELEASE ---
# The camera/lock is released during the GStreamer NULL transition. We make
# release idempotent and trigger it from every plausible exit path so the
# device is freed and the sensor powered down no matter how the worker dies
# (short of SIGKILL, which needs the systemd ExecStopPost backstop).
_released = threading.Event()


def release_camera():
    """Idempotent, synchronous teardown. Safe to call multiple times."""
    if _released.is_set():
        return
    _released.set()

    logging.info("Releasing camera and stopping workers...")
    stop_event.set()

    # Wake any client generators blocked on the condition so they can exit.
    try:
        with frame_condition:
            frame_condition.notify_all()
    except Exception:
        pass

    # This BLOCKS until the pipeline reaches NULL (camera actually released).
    try:
        if Tis is not None and Tis.pipeline is not None:
            Tis.Stop_pipeline()
    except Exception as e:
        logging.error(f"Error during camera release: {e}")


# atexit covers graceful interpreter shutdown (e.g. gunicorn worker exiting
# normally). Idempotent, so it is harmless if a signal handler ran first.
atexit.register(release_camera)


def signal_handler(sig, frame):
    logging.info(f"Signal {sig} received - shutting down...")
    release_camera()
    # Release is already complete (synchronous) before we exit, so the device
    # is freed regardless of how fast the process is reaped.
    sys.exit(0)


# Handle every signal that could be used to stop the process. Registering these
# at import time installs them in the gunicorn worker that imports this module.
for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGQUIT):
    try:
        signal.signal(_sig, signal_handler)
    except (ValueError, OSError):
        # Not in the main thread, or signal unsupported on this platform.
        pass


# --- MATH ---
def gaussian_2d(xy, amplitude, xo, yo, sigma_x, sigma_y, theta, offset):
    x, y = xy
    xo, yo = float(xo), float(yo)
    a = (np.cos(theta) ** 2) / (2 * sigma_x ** 2) + (np.sin(theta) ** 2) / (2 * sigma_y ** 2)
    b = -(np.sin(2 * theta)) / (4 * sigma_x ** 2) + (np.sin(2 * theta)) / (4 * sigma_y ** 2)
    c = (np.sin(theta) ** 2) / (2 * sigma_x ** 2) + (np.cos(theta) ** 2) / (2 * sigma_y ** 2)
    g = offset + amplitude * np.exp(-(a * ((x - xo) ** 2) + 2 * b * (x - xo) * (y - yo) + c * ((y - yo) ** 2)))
    return g.ravel()


def get_gaussian_center(frame):
    try:
        scale_percent = 20
        width = int(frame.shape[1] * scale_percent / 100)
        height = int(frame.shape[0] * scale_percent / 100)
        small_frame = cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA).astype(float)
        min_val = np.min(small_frame)
        small_frame -= min_val
        if np.max(small_frame) == 0:
            return (None, None)
        h, w = small_frame.shape
        x, y = np.meshgrid(np.arange(0, w), np.arange(0, h))
        max_loc = np.unravel_index(np.argmax(small_frame), small_frame.shape)
        initial_guess = (np.max(small_frame), max_loc[1], max_loc[0], 5, 5, 0, 0)
        popt, _ = curve_fit(gaussian_2d, (x, y), small_frame.ravel(), p0=initial_guess)
        return (popt[1] * (100 / scale_percent), popt[2] * (100 / scale_percent))
    except Exception:
        return (None, None)


# --- WORKER: DB WRITER ---
def sqlite_writer_loop():
    conn = get_db_connection()
    logging.info("DB Writer Started")
    last_commit_time = time.time()
    pending_writes = 0
    while not stop_event.is_set():
        try:
            data_row = write_queue.get(timeout=1)
            cursor = conn.cursor()
            cursor.execute("INSERT OR IGNORE INTO measurements VALUES (?,?,?,?,?,?,?)", data_row)
            write_queue.task_done()
            pending_writes += 1
            current_time = time.time()
            if pending_writes > 0 and (current_time - last_commit_time > 1.0 or pending_writes >= 50):
                conn.commit()
                last_commit_time = current_time
                pending_writes = 0
        except queue.Empty:
            if pending_writes > 0:
                conn.commit()
                pending_writes = 0
            continue
        except Exception:
            try:
                conn.close()
                time.sleep(1)
                conn = get_db_connection()
            except Exception:
                pass
    conn.close()


# --- WORKER: ANALYSIS (Gaussian Fit) ---
def analysis_loop():
    global cX, cY
    while not stop_event.is_set():
        try:
            frame_to_process = processing_queue.get(timeout=1)
            new_cx, new_cy = get_gaussian_center(frame_to_process)
            if new_cx is not None:
                cX, cY = new_cx, new_cy
                temps = read_temperatures()  # always length 4; float or None
                row_temps = [round(t, 2) if t is not None else None for t in temps]
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                write_queue.put((timestamp, round(cX, 2), round(cY, 2), *row_temps))
            processing_queue.task_done()
        except queue.Empty:
            continue
        except Exception:
            pass


# --- WORKER: ENCODER (Visualization) ---
def encoder_thread():
    """Consumes raw frames, generates heatmap+overlay and encodes jpeg once."""
    global global_jpeg_bytes, frame_id, cX, cY
    logging.info("Encoder thread started")

    while not stop_event.is_set():
        try:
            frame = encode_queue.get(timeout=1)
        except queue.Empty:
            continue

        try:
            vis_frame = frame  # Already a copy
            heatmap = cv2.applyColorMap(vis_frame, cv2.COLORMAP_JET)
            h, w = heatmap.shape[:2]

            center_x, center_y = w // 2, h // 2
            cv2.circle(heatmap, (center_x, center_y), h // 6, (255, 255, 255), 2)
            cv2.circle(heatmap, (center_x, center_y), 4, (0, 0, 0), -1)
            cv2.circle(heatmap, (center_x, center_y), 2, (255, 255, 255), -1)

            lx, ly = cX, cY
            if lx is not None and ly is not None:
                cv2.drawMarker(heatmap, (int(lx), int(ly)), (255, 255, 255), cv2.MARKER_CROSS, 20, 2)

            ret, buffer = cv2.imencode('.jpg', heatmap, [cv2.IMWRITE_JPEG_QUALITY, 60])
            if ret:
                with frame_condition:
                    global_jpeg_bytes = buffer.tobytes()
                    frame_id += 1
                    frame_condition.notify_all()
        except Exception as e:
            logging.error(f"Encoder error: {e}")
        finally:
            encode_queue.task_done()


# --- CALLBACK (PRODUCER) ---
class CustomData:
    def __init__(self):
        self.busy = False


CD = CustomData()


def on_new_image(tis, userdata):
    """Very fast callback: copy minimal data and enqueue."""
    if Tis is None:
        return

    raw_frame = tis.Get_image()
    if raw_frame is None:
        return

    frame_copy = raw_frame.copy()

    # Push to Video Pipeline (Non-blocking)
    try:
        encode_queue.put_nowait(frame_copy)
    except queue.Full:
        pass  # Drop frame if encoder is too slow (keeps camera alive)

    # Push to Analysis Pipeline (Trigger Logic)
    if IS_TRIGGER_MODE:
        minVal, maxVal, minLoc, maxLoc = cv2.minMaxLoc(frame_copy)
        if maxVal > 30:
            try:
                processing_queue.put_nowait(frame_copy)
            except queue.Full:
                pass


if Tis:
    Tis.Set_Image_Callback(on_new_image, CD)


# --- GENERATOR (CONSUMER) ---
def imagegenerator():
    """Efficient Generator using Condition Variable"""
    my_last_frame_id = 0

    while not stop_event.is_set():
        current_bytes = None

        with frame_condition:
            frame_condition.wait_for(lambda: frame_id > my_last_frame_id or stop_event.is_set())
            if stop_event.is_set():
                break
            current_bytes = global_jpeg_bytes
            my_last_frame_id = frame_id

        if current_bytes:
            try:
                yield (b'--imagingsource\r\n'
                       b'Content-Type: image/jpeg\r\n\r\n' + current_bytes + b'\r\n')
            except GeneratorExit:
                break
            except Exception:
                break


# --- ROUTES ---
@app.route('/')
def index():
    return render_template('index.html')


@app.route('/mjpeg_stream')
def stream():
    return Response(imagegenerator(), mimetype='multipart/x-mixed-replace; boundary=imagingsource')


@app.route('/api/latest_data')
def get_latest_data():
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT timestamp, cx, cy, temp1, temp2, temp3, temp4 FROM measurements ORDER BY timestamp DESC LIMIT 50")
        rows = cursor.fetchall()
        conn.close()
        if not rows:
            return jsonify({"timestamps": [], "cx": [], "cy": [], "temp1": [], "temp2": [], "temp3": [], "temp4": []})
        rows = rows[::-1]
        data = {
            "timestamps": [r[0] for r in rows],
            "cx": [r[1] if r[1] is not None else 0 for r in rows],
            "cy": [r[2] if r[2] is not None else 0 for r in rows],
            "temp1": [r[3] for r in rows],
            "temp2": [r[4] for r in rows],
            "temp3": [r[5] for r in rows],
            "temp4": [r[6] for r in rows]
        }
        return jsonify(data)
    except Exception as e:
        return jsonify({"error": str(e), "timestamps": []}), 500


@app.route('/api/set_mode', methods=['GET'])
def set_mode():
    global IS_TRIGGER_MODE, cX, cY
    mode = request.args.get('mode', '').lower()
    try:
        if mode == "trigger":
            if Tis and Tis.pipeline:
                Tis.Set_Property("TriggerMode", "On")
            IS_TRIGGER_MODE = True
        elif mode == "continuous":
            if Tis and Tis.pipeline:
                Tis.Set_Property("TriggerMode", "Off")
            IS_TRIGGER_MODE = False
            cX, cY = None, None
            with processing_queue.mutex:
                processing_queue.queue.clear()
        return jsonify({"status": "success", "mode": mode})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/download')
def download_data():
    from_date = request.args.get('from')
    to_date = request.args.get('to')

    def generate_csv():
        yield "Timestamp,CenterX,CenterY,T1,T2,T3,T4\n"
        conn = get_db_connection()
        cursor = conn.cursor()
        if from_date and to_date:
            cursor.execute("SELECT * FROM measurements WHERE timestamp BETWEEN ? AND ? ORDER BY timestamp DESC", (from_date, to_date))
        else:
            cursor.execute("SELECT * FROM measurements ORDER BY timestamp DESC LIMIT 20000")
        while True:
            row = cursor.fetchone()
            if row is None:
                break
            yield ",".join(map(str, row)) + "\n"
        conn.close()

    filename = f"pi_data_{datetime.now().strftime('%Y%m%d_%H%M')}.csv"
    return Response(stream_with_context(generate_csv()), mimetype='text/csv',
                    headers={"Content-Disposition": f"attachment; filename={filename}"})


# --- STARTUP ---
def start_threads():
    if not any(t.name == "SQLWriter" for t in threading.enumerate()):
        threading.Thread(target=sqlite_writer_loop, name="SQLWriter", daemon=True).start()
    if not any(t.name == "Analysis" for t in threading.enumerate()):
        threading.Thread(target=analysis_loop, name="Analysis", daemon=True).start()
    if not any(t.name == "Encoder" for t in threading.enumerate()):
        threading.Thread(target=encoder_thread, name="Encoder", daemon=True).start()


start_threads()


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000, threaded=True)
