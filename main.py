from datetime import datetime
import json
import time
import TIS
import cv2
import numpy as np
import logging
import sys
import threading
import queue  # For thread-safe communication
import csv    # For CSV writing
from flask import Flask, Response, request, jsonify
from scipy.optimize import curve_fit
from adafruit_tmp117 import TMP117
import board

app = Flask(__name__)
Tis = TIS.TIS()

# --- Global Variables ---
latest_frame = None
cX, cY = 0, 0

# --- QUEUE SETUP ---
# Infinite size queue. Analysis thread puts data here. Writer thread takes it.
write_queue = queue.Queue()

# --- Camera & Sensor Setup ---
try:
    print("Loading camera device state...")
    Tis.loadstatefile("devicestate.json")
    Tis.Start_pipeline()
except Exception as error:
    print(error)
    quit()

i2c = board.I2C()
try:
    temp_sensors = [
        TMP117(i2c, address=0x48),
        TMP117(i2c, address=0x49),
        TMP117(i2c, address=0x4A),
        TMP117(i2c, address=0x4B)
    ]
except ValueError as e:
    print(f"Sensor Init Error: {e}")
    temp_sensors = []

# --- MATH: FULL 2D GAUSSIAN ---
def gaussian_2d(xy, amplitude, xo, yo, sigma_x, sigma_y, theta, offset):
    x, y = xy
    xo = float(xo)
    yo = float(yo)
    a = (np.cos(theta)**2)/(2*sigma_x**2) + (np.sin(theta)**2)/(2*sigma_y**2)
    b = -(np.sin(2*theta))/(4*sigma_x**2) + (np.sin(2*theta))/(4*sigma_y**2)
    c = (np.sin(theta)**2)/(2*sigma_x**2) + (np.cos(theta)**2)/(2*sigma_y**2)
    g = offset + amplitude*np.exp( - (a*((x-xo)**2) + 2*b*(x-xo)*(y-yo) + c*((y-yo)**2)))
    return g.ravel()

def get_gaussian_center(frame):
    # 1. Downscale for Performance (Critical for Pi 4)
    scale_percent = 20 
    width = int(frame.shape[1] * scale_percent / 100)
    height = int(frame.shape[0] * scale_percent / 100)
    dim = (width, height)
    small_frame = cv2.resize(frame, dim, interpolation=cv2.INTER_AREA)

    # 2. Background Subtraction
    small_frame = small_frame.astype(float)
    min_val = np.min(small_frame)
    small_frame -= min_val
    
    if np.max(small_frame) == 0:
        return (None, None)

    # 3. Create Grid
    h, w = small_frame.shape
    x = np.arange(0, w)
    y = np.arange(0, h)
    x, y = np.meshgrid(x, y)
    
    # 4. Initial Guess
    max_loc = np.unravel_index(np.argmax(small_frame, axis=None), small_frame.shape)
    guess_y, guess_x = max_loc
    
    initial_guess = (np.max(small_frame), guess_x, guess_y, 5, 5, 0, 0)
    
    try:
        # 5. The Heavy Lifting
        popt, pcov = curve_fit(gaussian_2d, (x, y), small_frame.ravel(), p0=initial_guess)
        
        # 6. Scale coordinates back to original size
        real_x = popt[1] * (100 / scale_percent)
        real_y = popt[2] * (100 / scale_percent)
        return (real_x, real_y)
        
    except (RuntimeError, ValueError):
        # Fallback to brightest pixel
        return (float(guess_x * (100/scale_percent)), float(guess_y * (100/scale_percent)))

# --- FILE WRITER THREAD (CONSUMER) ---
def file_writer_loop():
    filename = "data.csv"
    logging.info(f"Starting file writer service for {filename}")
    
    with open(filename, mode='a', newline='') as f:
        writer = csv.writer(f)
        if f.tell() == 0:
            writer.writerow(["Timestamp", "CenterX", "CenterY", "Temp1", "Temp2", "Temp3", "Temp4"])
            f.flush()

        while True:
            try:
                data_row = write_queue.get()
                writer.writerow(data_row)
                f.flush()
                write_queue.task_done()
            except Exception as e:
                logging.error(f"Write error: {e}")

writer_thread = threading.Thread(target=file_writer_loop, daemon=True)
writer_thread.start()

# --- ANALYSIS THREAD (PRODUCER) ---
perf_logger = logging.getLogger("perf")
perf_logger.setLevel(logging.INFO)
perf_logger.addHandler(logging.StreamHandler(sys.stdout))

def analysis_loop():
    global cX, cY, latest_frame
    
    while True:
        frame_to_process = None
        if latest_frame is not None:
             frame_to_process = latest_frame.copy()
        
        if frame_to_process is not None:
            t0 = time.perf_counter()
            
            # --- 2D MATH ---
            new_cx, new_cy = get_gaussian_center(frame_to_process)
            
            math_time = (time.perf_counter() - t0) * 1000
            
            if new_cx is not None:
                cX, cY = new_cx, new_cy
                
                # --- SENSORS ---
                t2 = time.perf_counter()
                try:
                    temps = [t.temperature for t in temp_sensors]
                except Exception:
                    temps = [0, 0, 0, 0]
                sensor_time = (time.perf_counter() - t2) * 1000
                
                # --- QUEUE PUSH ---
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
                csv_data = [timestamp, f"{cX:.2f}", f"{cY:.2f}"] + [f"{t:.2f}" for t in temps]
                write_queue.put(csv_data)
                json
                perf_logger.info(f"2D MATH: {math_time:.1f}ms | SENSORS: {sensor_time:.1f}ms | QUEUE: {write_queue.qsize()}")

        time.sleep(0.05) 

analysis_thread = threading.Thread(target=analysis_loop, daemon=True)
analysis_thread.start()

# --- FAST CALLBACK ---
class CustomData:
    def __init__(self):
        self.busy = False
CD = CustomData()

def on_new_image(tis, userdata):
    global latest_frame
    if userdata.busy: return
    userdata.busy = True
    frame = tis.Get_image()
    if frame is not None:
        latest_frame = frame
    userdata.busy = False

Tis.Set_Image_Callback(on_new_image, CD)

# --- FLASK STREAM ---
def imagegenerator():
    global cX, cY
    while True:
        if Tis.newsample:
            frame = Tis.Get_image()
            Tis.newsample = False
            if frame is not None:
                heatmap = cv2.applyColorMap(frame, cv2.COLORMAP_JET)
                
                if cX and cY:
                    cv2.drawMarker(heatmap, (int(cX), int(cY)), (255, 255, 255), cv2.MARKER_CROSS, 30, 2)
                
                ret, buffer = cv2.imencode('.jpg', heatmap, [cv2.IMWRITE_JPEG_QUALITY, 40])
                if ret:
                    yield (b'--imagingsource\r\n' b'Content-Type: image/jpeg\r\n\r\n' + buffer.tobytes() + b'\r\n')
        else:
            time.sleep(0.001)

@app.route('/mjpeg_stream')
def imagestream():
    return Response(imagegenerator(), mimetype='multipart/x-mixed-replace; boundary=imagingsource')

@app.route('/')
def index():
    return Response(imagegenerator(), mimetype='multipart/x-mixed-replace; boundary=imagingsource') 


@app.route('/api/set_mode', methods=['GET', 'POST'])
def set_mode():
    """
    Switch between Trigger Mode and Continuous Mode.
    Usage:
      GET /api/set_mode?mode=trigger
      GET /api/set_mode?mode=continuous
    """
    # Get mode from query string (GET) or JSON body (POST)
    mode = request.args.get('mode') or (request.json.get('mode') if request.is_json else None)

    if not mode:
        return jsonify({"status": "error", "message": "Missing 'mode' parameter. Use 'trigger' or 'continuous'."}), 400

    mode = mode.lower()

    try:
        if mode == "trigger":
            # Enable Hardware Trigger
            # Based on your JSON, the property is "TriggerMode" and value is "On"
            Tis.Set_Property("TriggerMode", "On")
            logging.info("API Command: Switched to Trigger Mode (On)")
            return jsonify({
                "status": "success", 
                "current_mode": "Trigger Mode (On)", 
                "description": "Waiting for hardware pulse (PicoBlade)."
            })

        elif mode == "continuous":
            # Disable Hardware Trigger (Free run)
            Tis.Set_Property("TriggerMode", "Off")
            logging.info("API Command: Switched to Continuous Mode (Off)")
            return jsonify({
                "status": "success", 
                "current_mode": "Continuous Mode (Off)", 
                "description": "Camera streaming freely."
            })

        else:
            return jsonify({"status": "error", "message": f"Invalid mode '{mode}'. Use 'trigger' or 'continuous'."}), 400

    except Exception as e:
        logging.error(f"Failed to set TriggerMode: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    app.run(host='0.0.0.0', threaded=True)