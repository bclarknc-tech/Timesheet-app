"""
Trend & Product Scanner & Video Clipper Node (Runs on Spare PC: 192.168.86.70)
Provides API endpoints for FBA scanning, trend tracking, and receiving pushed videos from Main PC.
"""
from flask import Flask, request, jsonify, render_template_string
import subprocess
import os
import datetime
import threading
import time
import glob
import sys

app = Flask(__name__)
SECRET_TOKEN = "jarvis-local-master-2026"

# In-memory log buffer
EXEC_LOGS = []
def log_action(msg):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"[{timestamp}] {msg}"
    print(entry)
    EXEC_LOGS.append(entry)
    if len(EXEC_LOGS) > 250:
        EXEC_LOGS.pop(0)

def verify_auth():
    auth = request.headers.get('Authorization', '')
    if auth != f"Bearer {SECRET_TOKEN}":
        return False
    return True

LOCAL_CLIPPER_BASE = r"\\192.168.86.62\Video Clipper"
INPUT_DIR = os.path.join(LOCAL_CLIPPER_BASE, "Input")
OUTPUT_DIR = os.path.join(LOCAL_CLIPPER_BASE, "Output")
PROCESSED_DIR = os.path.join(LOCAL_CLIPPER_BASE, "Processed")

def ensure_clipper_dirs():
    for d in [INPUT_DIR, OUTPUT_DIR, PROCESSED_DIR]:
        for sub in ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]:
            os.makedirs(os.path.join(d, sub), exist_ok=True)

DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Trend & Product Scanner - Live Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    <meta http-equiv="refresh" content="5">
</head>
<body class="bg-slate-900 text-slate-100 min-h-screen p-8 font-sans">
    <div class="max-w-5xl mx-auto">
        <header class="flex justify-between items-center mb-8 pb-4 border-b border-slate-800">
            <div>
                <h1 class="text-3xl font-extrabold text-white">⚡ Trend & Product Scanner</h1>
                <p class="text-slate-400 text-sm">Spare PC Automation Center (192.168.86.70)</p>
            </div>
            <div class="flex items-center gap-3">
                <span class="inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 animate-pulse">
                    ● Node Active & Receiving
                </span>
                <button onclick="triggerScan()" class="px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white font-bold rounded-lg text-sm cursor-pointer transition">Run Immediate Scan</button>
            </div>
        </header>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
            <div class="bg-slate-800 border border-slate-700 rounded-xl p-6 shadow">
                <p class="text-slate-400 text-sm font-medium">Node IP</p>
                <p class="text-2xl font-black text-white mt-1">192.168.86.70</p>
            </div>
            <div class="bg-slate-800 border border-slate-700 rounded-xl p-6 shadow">
                <p class="text-slate-400 text-sm font-medium">Video Storage</p>
                <p class="text-2xl font-black text-emerald-400 mt-1">C:\\VideoClipper (Local)</p>
            </div>
            <div class="bg-slate-800 border border-slate-700 rounded-xl p-6 shadow">
                <p class="text-slate-400 text-sm font-medium">Vault Sync</p>
                <p class="text-2xl font-black text-indigo-400 mt-1">Jarvis 2.0 (Active)</p>
            </div>
        </div>

        <div class="bg-slate-800 border border-slate-700 rounded-2xl overflow-hidden shadow-xl mb-8">
            <div class="px-6 py-4 border-b border-slate-700 font-bold text-lg text-white flex justify-between items-center">
                <span>🖥️ Live Execution & Pushed Video Stream</span>
                <span class="text-xs text-slate-400 font-normal">Auto-refreshing every 5s</span>
            </div>
            <div class="p-6 bg-slate-950 font-mono text-xs text-emerald-400 h-96 overflow-y-auto space-y-1">
                {% for log in logs %}
                    <div>{{ log }}</div>
                {% endfor %}
            </div>
        </div>
    </div>
    <script>
        function triggerScan() {
            fetch('/api/trigger-scan', {method: 'POST', headers: {'Authorization': 'Bearer jarvis-local-master-2026'}})
                .then(r => r.json())
                .then(res => { alert(res.message || 'Scan triggered!'); location.reload(); });
        }
    </script>
</body>
</html>
"""

def run_scans():
    log_action("[Worker] Starting market & FBA data collection cycle...")
    try:
        res1 = subprocess.run("python fba_scanner.py", shell=True, capture_output=True, text=True, cwd=os.path.dirname(__file__))
        for line in res1.stdout.splitlines():
            if line.strip(): log_action(f"  [FBA] {line}")
    except Exception as e:
        log_action(f"[Worker] FBA scan error: {e}")
        
    try:
        res2 = subprocess.run("python trend_scanner.py", shell=True, capture_output=True, text=True, cwd=os.path.dirname(__file__))
        for line in res2.stdout.splitlines():
            if line.strip(): log_action(f"  [Trend] {line}")
    except Exception as e:
        log_action(f"[Worker] Trend scan error: {e}")

def background_scheduler():
    time.sleep(5)
    while True:
        log_action("[Scheduler] === Starting Continuous 12-Hour Scanning Block ===")
        block_start = time.time()
        while time.time() - block_start < 43200:
            run_scans()
            log_action("[Scheduler] Sweeps complete. Sleeping 2 minutes...")
            time.sleep(120)
            
        log_action("[Scheduler] === 12 Hours Reached. Pausing for 5 minutes ===")
        time.sleep(300)

def video_clipper_worker():
    ensure_clipper_dirs()
    subfolders = ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]
    log_action("[Video Clipper Worker] Started monitoring network share: " + INPUT_DIR)
    time.sleep(10)
    while True:
        try:
            for sub in subfolders:
                in_sub = os.path.join(INPUT_DIR, sub)
                out_sub = os.path.join(OUTPUT_DIR, sub)
                proc_sub = os.path.join(PROCESSED_DIR, sub)
                
                if not os.path.exists(in_sub):
                    continue
                    
                video_files = []
                for ext in ["*.mp4", "*.mov", "*.mkv", "*.avi"]:
                    video_files.extend(glob.glob(os.path.join(in_sub, ext)))
                    
                for video_path in video_files:
                    filename = os.path.basename(video_path)
                    name_no_ext, _ = os.path.splitext(filename)
                    log_action(f"[Video Clipper] Found new source video on M drive: {filename} in {sub}")
                    
                    timestamps = [0, 60, 120]
                    for i, ts in enumerate(timestamps, 1):
                        output_filename = f"{name_no_ext}_clip_{i}.mp4"
                        output_path = os.path.join(out_sub, output_filename)
                        if os.path.exists(output_path):
                            continue
                        log_action(f"[Video Clipper] Generating 9:16 vertical clip #{i} starting at {ts}s...")
                        cmd = f'ffmpeg -y -ss {ts} -i "{video_path}" -t 30 -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -c:v libx264 -preset fast -c:a aac "{output_path}"'
                        try:
                            res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=120)
                            if res.returncode == 0:
                                log_action(f"  -> Saved viral short to M drive: {output_filename}")
                            else:
                                log_action(f"  -> FFmpeg error on clip {i}: {res.stderr}")
                        except Exception as e:
                            log_action(f"  -> Exception clipping video: {e}")
                            
                    try:
                        dest_processed = os.path.join(proc_sub, filename)
                        if os.path.exists(dest_processed):
                            os.remove(dest_processed)
                        os.rename(video_path, dest_processed)
                        log_action(f"[Video Clipper] Moved source to processed on M drive: {filename}")
                    except Exception as e:
                        log_action(f"Error moving processed file: {e}")
        except Exception as e:
            log_action(f"Clipper worker error: {e}")
        time.sleep(15)

@app.route('/dashboard', methods=['GET'])
def dashboard():
    return render_template_string(DASHBOARD_HTML, logs=reversed(EXEC_LOGS))

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'online',
        'hostname': os.environ.get('COMPUTERNAME', 'SparePC'),
        'time': datetime.datetime.now().isoformat()
    })

@app.route('/api/trigger-scan', methods=['POST'])
def trigger_scan():
    log_action("Immediate scan requested via Live Dashboard.")
    threading.Thread(target=run_scans).start()
    return jsonify({'success': True, 'message': 'Scan dispatched instantly.'})

@app.route('/upload-video', methods=['POST'])
def upload_video():
    if not verify_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    subfolder = request.form.get('subfolder', 'General')
    if 'file' not in request.files:
        return jsonify({'success': False, 'error': 'No file part'}), 400
        
    file = request.files['file']
    if file.filename == '':
        return jsonify({'success': False, 'error': 'No selected file'}), 400
        
    ensure_clipper_dirs()
    target_dir = os.path.join(INPUT_DIR, subfolder)
    os.makedirs(target_dir, exist_ok=True)
    
    filepath = os.path.join(target_dir, file.filename)
    file.save(filepath)
    log_action(f"[Pusher] Received video from Main PC: {file.filename} -> {subfolder}")
    
    # Trigger local clipping thread
    def clip_pushed_video():
        log_action(f"[Clipper] Processing pushed video: {file.filename}")
        out_sub = os.path.join(OUTPUT_DIR, subfolder)
        os.makedirs(out_sub, exist_ok=True)
        name_no_ext, _ = os.path.splitext(file.filename)
        
        for i, ts in enumerate([0, 60, 120], 1):
            output_filename = f"{name_no_ext}_clip_{i}.mp4"
            output_path = os.path.join(out_sub, output_filename)
            if os.path.exists(output_path):
                continue
            cmd = f'ffmpeg -y -ss {ts} -i "{filepath}" -t 30 -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -c:v libx264 -preset fast -c:a aac "{output_path}"'
            try:
                res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=120)
                if res.returncode == 0:
                    log_action(f"  -> Generated viral short: {output_filename}")
            except Exception as e:
                log_action(f"  -> Clip error: {e}")
                
        # Move to processed
        proc_sub = os.path.join(PROCESSED_DIR, subfolder)
        os.makedirs(proc_sub, exist_ok=True)
        try:
            dest_proc = os.path.join(proc_sub, file.filename)
            if os.path.exists(dest_proc):
                os.remove(dest_proc)
            os.rename(filepath, dest_proc)
            log_action(f"[Clipper] Finished & archived: {file.filename}")
        except Exception as e:
            log_action(f"[Clipper] Archive error: {e}")

    threading.Thread(target=clip_pushed_video).start()
    return jsonify({'success': True, 'message': f'File {file.filename} received and queued for clipping.'})

@app.route('/api/update-and-restart', methods=['POST'])
def update_and_restart():
    if not verify_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    log_action("Update and restart requested. Pulling from git...")
    try:
        subprocess.run("git pull origin main", shell=True, check=True, cwd=os.path.dirname(__file__))
        log_action("Git pull successful. Restarting process...")
        def do_restart():
            time.sleep(1)
            os.execv(sys.executable, ['python'] + sys.argv)
        threading.Thread(target=do_restart).start()
        return jsonify({'success': True, 'message': 'Pull successful, restarting daemon...'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    log_action("Starting Trend & Product Scanner on 0.0.0.0:8899...")
    ensure_clipper_dirs()
    sched_thread = threading.Thread(target=background_scheduler, daemon=True)
    sched_thread.start()
    clipper_thread = threading.Thread(target=video_clipper_worker, daemon=True)
    clipper_thread.start()
    log_action("24/7 Automation Daemon initialized with Network Share Video Clipper.")
    
    app.run(host='0.0.0.0', port=8899)
