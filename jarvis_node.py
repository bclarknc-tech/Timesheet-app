"""
Jarvis Master Node Daemon (Runs on Spare PC: 192.168.86.70)
Provides a secure local API + Live Web Dashboard for task execution, 
FBA scanning, market trend tracking, automated video clipping, and 24/7 continuous looping scheduler.
"""
from flask import Flask, request, jsonify, render_template_string
import subprocess
import os
import datetime
import threading
import time
import glob

app = Flask(__name__)
SECRET_TOKEN = "jarvis-local-master-2026"

# In-memory log buffer
EXEC_LOGS = []
def log_action(msg):
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"[{timestamp}] {msg}"
    print(entry)
    EXEC_LOGS.append(entry)
    if len(EXEC_LOGS) > 200:
        EXEC_LOGS.pop(0)

def verify_auth():
    auth = request.headers.get('Authorization', '')
    if auth != f"Bearer {SECRET_TOKEN}":
        return False
    return True

DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Jarvis Master Node - Live Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    <meta http-equiv="refresh" content="3">
</head>
<body class="bg-slate-900 text-slate-100 min-h-screen p-8 font-sans">
    <div class="max-w-5xl mx-auto">
        <header class="flex justify-between items-center mb-8 pb-4 border-b border-slate-800">
            <div>
                <h1 class="text-3xl font-extrabold text-white">⚡ Jarvis Master Node</h1>
                <p class="text-slate-400 text-sm">Spare PC Automation Center (192.168.86.70)</p>
            </div>
            <div class="flex items-center gap-3">
                <span class="inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 animate-pulse">
                    ● Continuous 24/7 Loop Active
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
                <p class="text-slate-400 text-sm font-medium">Execution Mode</p>
                <p class="text-2xl font-black text-emerald-400 mt-1">Continuous Looping</p>
            </div>
            <div class="bg-slate-800 border border-slate-700 rounded-xl p-6 shadow">
                <p class="text-slate-400 text-sm font-medium">Vault Sync</p>
                <p class="text-2xl font-black text-indigo-400 mt-1">Active (OneDrive)</p>
            </div>
        </div>

        <div class="bg-slate-800 border border-slate-700 rounded-2xl overflow-hidden shadow-xl mb-8">
            <div class="px-6 py-4 border-b border-slate-700 font-bold text-lg text-white flex justify-between items-center">
                <span>🖥️ Live Execution & Scraper Stream</span>
                <span class="text-xs text-slate-400 font-normal">Auto-refreshing every 3s</span>
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

def run_all_scans():
    log_action("[Worker] Starting continuous market & FBA scan cycle...")
    try:
        res1 = subprocess.run("python fba_scanner.py", shell=True, capture_output=True, text=True, cwd=os.path.dirname(__file__))
        for line in res1.stdout.splitlines():
            if line.strip(): log_action(f"  [FBA] {line}")
        log_action("[Worker] FBA scan cycle completed. Results synced to vault.")
    except Exception as e:
        log_action(f"[Worker] FBA scan error: {e}")
        
    try:
        res2 = subprocess.run("python trend_scanner.py", shell=True, capture_output=True, text=True, cwd=os.path.dirname(__file__))
        for line in res2.stdout.splitlines():
            if line.strip(): log_action(f"  [Trend] {line}")
        log_action("[Worker] Trend scan cycle completed. Results synced to vault.")
    except Exception as e:
        log_action(f"[Worker] Trend scan error: {e}")

def background_scheduler():
    # Run immediately on startup
    time.sleep(5)
    while True:
        run_all_scans()
        log_action("[Worker] Cycle finished. Cooling down for 60 seconds before next scan...")
        time.sleep(60) # Loop continuously every 60 seconds

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
    threading.Thread(target=run_all_scans).start()
    return jsonify({'success': True, 'message': 'Scan dispatched instantly.'})

@app.route('/exec', methods=['POST'])
def execute_command():
    if not verify_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    data = request.json or {}
    cmd = data.get('command')
    if not cmd:
        return jsonify({'error': 'No command provided'}), 400
    
    log_action(f"Executing: {cmd}")
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300, cwd=data.get('cwd', None))
        log_action(f"Finished: {cmd} (Exit: {result.returncode})")
        return jsonify({
            'success': True,
            'exit_code': result.returncode,
            'stdout': result.stdout,
            'stderr': result.stderr
        })
    except Exception as e:
        log_action(f"Error executing {cmd}: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/clip-video', methods=['POST'])
def clip_video():
    if not verify_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    data = request.json or {}
    input_file = data.get('input_file')
    output_file = data.get('output_file', 'viral_short.mp4')
    start_time = data.get('start', '00:00:00')
    duration = data.get('duration', '30')
    
    if not input_file or not os.path.exists(input_file):
        return jsonify({'success': False, 'error': 'Input video file not found'}), 400
        
    cmd = f'ffmpeg -y -ss {start_time} -i "{input_file}" -t {duration} -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -c:v libx264 -preset fast -c:a aac "{output_file}"'
    
    log_action(f"Clipping video: {input_file} -> {output_file}")
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            log_action(f"Successfully created viral clip: {output_file}")
            return jsonify({'success': True, 'output_file': output_file})
        else:
            log_action(f"FFmpeg error: {result.stderr}")
            return jsonify({'success': False, 'error': result.stderr}), 500
    except Exception as e:
        log_action(f"Video clipping exception: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    log_action("Starting Jarvis Master Node on 0.0.0.0:8899...")
    sched_thread = threading.Thread(target=background_scheduler, daemon=True)
    sched_thread.start()
    log_action("24/7 Continuous Looping Worker initialized.")
    
    app.run(host='0.0.0.0', port=8899)
