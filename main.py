from datetime import datetime
import json
import time
import TIS
import cv2
import numpy as np
import logging
import sys
import threading
import queue
import sqlite3
import board
from flask import Flask, Response, request, jsonify, stream_with_context, render_template
from scipy.optimize import curve_fit
from adafruit_tmp117 import TMP117
import io
from flask_cors import CORS
import os
import signal

# --- LOGGING SETUP ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__)
CORS(app)

# --- Configuration ---
DB_NAME = "/opt/thermal_cam/sensor_data.db"
DEVICE_STATE_FILE = "devicestate.json"

# --- Queues & Sync ---
processing_queue = queue.Queue(maxsize=10)  
write_queue = queue.Queue()
stop_event = threading.Event()

# --- Global Variables & Locks ---
cX, cY = None, None  
frame_id = 0  # To track new frames
frame_lock = threading.Lock()
global_jpeg_bytes = None # Stores the finished frame for all clients
IS_TRIGGER_MODE = False 
Tis = None 

# --- DATABASE HELPER ---
def get_db_connection():
    """Creates a robust DB connection with WAL mode and Timeout"""
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

# --- HARDWARE SETUP ---
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

i2c = board.I2C()
try:
    temp_sensors = [TMP117(i2c, address=0x48), TMP117(i2c, address=0x49),
                    TMP117(i2c, address=0x4A), TMP117(i2c, address=0x4B)]
except Exception as e:
    logging.error(f"Sensor Init Error: {e}")
    temp_sensors = []

# --- MATH ---
def gaussian_2d(xy, amplitude, xo, yo, sigma_x, sigma_y, theta, offset):
    x, y = xy
    xo, yo = float(xo), float(yo)
    a = (np.cos(theta)**2)/(2*sigma_x**2) + (np.sin(theta)**2)/(2*sigma_y**2)
    b = -(np.sin(2*theta))/(4*sigma_x**2) + (np.sin(2*theta))/(4*sigma_y**2)
    c = (np.sin(theta)**2)/(2*sigma_x**2) + (np.cos(theta)**2)/(2*sigma_y**2)
    g = offset + amplitude*np.exp( - (a*((x-xo)**2) + 2*b*(x-xo)*(y-yo) + c*((y-yo)**2)))
    return g.ravel()

def get_gaussian_center(frame):
    try:
        scale_percent = 20  
        width = int(frame.shape[1] * scale_percent / 100)
        height = int(frame.shape[0] * scale_percent / 100)
        small_frame = cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA).astype(float)
        min_val = np.min(small_frame)
        small_frame -= min_val
        if np.max(small_frame) == 0: return (None, None)
        h, w = small_frame.shape
        x, y = np.meshgrid(np.arange(0, w), np.arange(0, h))
        max_loc = np.unravel_index(np.argmax(small_frame), small_frame.shape)
        initial_guess = (np.max(small_frame), max_loc[1], max_loc[0], 5, 5, 0, 0)
        popt, _ = curve_fit(gaussian_2d, (x, y), small_frame.ravel(), p0=initial_guess)
        return (popt[1] * (100/scale_percent), popt[2] * (100/scale_percent))
    except:
        return (None, None)

# --- WORKER THREADS ---
def sqlite_writer_loop():
    """Batched DB Writer to prevent locking."""
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
            
            # Smart Commit (Only once per second or every 50 records)
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
        except Exception as e:
            logging.error(f"DB Write error: {e}")
            try:
                conn.close()
                time.sleep(1)
                conn = get_db_connection()
            except: pass
    conn.close()

def analysis_loop():
    global cX, cY
    while not stop_event.is_set():
        try:
            frame_to_process = processing_queue.get(timeout=1)
            new_cx, new_cy = get_gaussian_center(frame_to_process)
            
            if new_cx is not None:
                cX, cY = new_cx, new_cy
                try: temps = [t.temperature for t in temp_sensors]
                except: temps = [0, 0, 0, 0]
                
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                write_queue.put((timestamp, round(cX, 2), round(cY, 2), *[round(t, 2) for t in temps]))
            
            processing_queue.task_done()
        except queue.Empty: continue
        except Exception: pass

# --- CALLBACK (HEAVY LIFTING HERE) ---
class CustomData:
    def __init__(self): self.busy = False
CD = CustomData()

def on_new_image(tis, userdata):
    global global_jpeg_bytes, frame_id, cX, cY
    if Tis is None: return
    
    raw_frame = tis.Get_image()
    if raw_frame is None: return
    
    # Deep Copy
    vis_frame = raw_frame.copy()

    # Process Once
    heatmap = cv2.applyColorMap(vis_frame, cv2.COLORMAP_JET)
    h, w = heatmap.shape[:2]
    
    # Draw overlays
    cv2.circle(heatmap, (w//2, h//2), h//6, (255, 255, 255), 2)
    if cX is not None and cY is not None:
        cv2.drawMarker(heatmap, (int(cX), int(cY)), (255, 255, 255), cv2.MARKER_CROSS, 20, 2)

    # Encode Once
    ret, buffer = cv2.imencode('.jpg', heatmap, [cv2.IMWRITE_JPEG_QUALITY, 60])
    
    if ret:
        # Save to Global (Thread-Safe)
        with frame_lock:
            global_jpeg_bytes = buffer.tobytes()
            frame_id += 1

    # Trigger Logic
    if IS_TRIGGER_MODE:
        minVal, maxVal, minLoc, maxLoc = cv2.minMaxLoc(raw_frame)
        if maxVal > 30:  
            if not processing_queue.full():
                processing_queue.put(raw_frame)

if Tis:
    Tis.Set_Image_Callback(on_new_image, CD)

# --- LIGHTWEIGHT GENERATOR ---
def imagegenerator():
    global frame_id
    my_last_id = 0
    
    while not stop_event.is_set():
        if frame_id > my_last_id:
            with frame_lock:
                current_bytes = global_jpeg_bytes
                my_last_id = frame_id
            
            if current_bytes:
                yield (b'--imagingsource\r\n' 
                       b'Content-Type: image/jpeg\r\n\r\n' + current_bytes + b'\r\n')
        else:
            time.sleep(0.01)

# --- FLASK ROUTES (Added Back) ---

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
            if Tis: Tis.Set_Property("TriggerMode", "On")
            IS_TRIGGER_MODE = True
        elif mode == "continuous":
            if Tis: Tis.Set_Property("TriggerMode", "Off")
            IS_TRIGGER_MODE = False
            cX, cY = None, None
            with processing_queue.mutex: processing_queue.queue.clear()
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
            if row is None: break
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

start_threads()

def signal_handler(sig, frame):
    logging.info("Shutting down...")
    stop_event.set()
    if Tis: Tis.Stop_pipeline()
    sys.exit(0)
    
signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000, threaded=True)
