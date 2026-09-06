"""
Trend & Product Scanner & Video Clipper Daemon (Runs on Spare PC: 192.168.86.70)
Provides a secure local API + Live Web Dashboard for task execution, 
FBA scanning, multi-source market trend tracking, and automated 24/7 video clipping with file queue status.
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
    if len(EXEC_LOGS) > 250:
        EXEC_LOGS.pop(0)

def verify_auth():
    auth = request.headers.get('Authorization', '')
    if auth != f"Bearer {SECRET_TOKEN}":
        return False
    return True

def get_clipper_status():
    vault_base = r"C:\Users\bclar\OneDrive\Desktop\Jarvis 2.0\04 - Active Projects\Video Clipper"
    input_dir = os.path.join(vault_base, "Input")
    output_dir = os.path.join(vault_base, "Output")
    
    queues = {}
    outputs = {}
    
    subfolders = ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]
    for sub in subfolders:
        in_path = os.path.join(input_dir, sub)
        out_path = os.path.join(output_dir, sub)
        
        queues[sub] = []
        if os.path.exists(in_path):
            for ext in ["*.mp4", "*.mov", "*.mkv", "*.avi"]:
                queues[sub].extend([os.path.basename(f) for f in glob.glob(os.path.join(in_path, ext))])
                
        outputs[sub] = []
        if os.path.exists(out_path):
            outputs[sub].extend([os.path.basename(f) for f in glob.glob(os.path.join(out_path, "*.mp4"))])
            
    return queues, outputs

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
    <div class="max-w-6xl mx-auto">
        <header class="flex justify-between items-center mb-8 pb-4 border-b border-slate-800">
            <div>
                <h1 class="text-3xl font-extrabold text-white">⚡ Trend & Product Scanner</h1>
                <p class="text-slate-400 text-sm">Spare PC Automation Center (192.168.86.70)</p>
            </div>
            <div class="flex items-center gap-3">
                <span class="inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 animate-pulse">
                    ● Video Clipper & Scraper Active
                </span>
                <button onclick="triggerClipper()" class="px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white font-bold rounded-lg text-sm cursor-pointer transition">Run Clipper Now</button>
            </div>
        </header>

        <!-- Video Clipper Queue Grid -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
            <div class="bg-slate-800 border border-slate-700 rounded-2xl p-6 shadow-xl">
                <h2 class="text-lg font-bold mb-4 text-white flex items-center gap-2">📥 Input Queue (Waiting to Clip)</h2>
                <div class="space-y-4">
                    {% for sub, files in queues.items() %}
                        <div class="bg-slate-900/60 p-3 rounded-xl border border-slate-700/50">
                            <span class="text-xs font-semibold uppercase tracking-wider text-indigo-400">{{ sub }}</span>
                            {% if files %}
                                <ul class="mt-2 space-y-1 text-sm text-slate-200">
                                    {% for f in files %}
                                        <li class="flex items-center gap-2">🎬 {{ f }}</li>
                                    {% endfor %}
                                </ul>
                            {% else %}
                                <p class="text-xs text-slate-500 mt-1">No files waiting in queue.</p>
                            {% endif %}
                        </div>
                    {% endfor %}
                </div>
            </div>

            <div class="bg-slate-800 border border-slate-700 rounded-2xl p-6 shadow-xl">
                <h2 class="text-lg font-bold mb-4 text-white flex items-center gap-2">✨ Finished 9:16 Viral Shorts</h2>
                <div class="space-y-4">
                    {% for sub, files in outputs.items() %}
                        <div class="bg-slate-900/60 p-3 rounded-xl border border-slate-700/50">
                            <span class="text-xs font-semibold uppercase tracking-wider text-emerald-400">{{ sub }}</span>
                            {% if files %}
                                <ul class="mt-2 space-y-1 text-sm text-slate-200">
                                    {% for f in files %}
                                        <li class="flex items-center gap-2">🚀 {{ f }}</li>
                                    {% endfor %}
                                </ul>
                            {% else %}
                                <p class="text-xs text-slate-500 mt-1">No clips generated yet.</p>
                            {% endif %}
                        </div>
                    {% endfor %}
                </div>
            </div>
        </div>

        <div class="bg-slate-800 border border-slate-700 rounded-2xl overflow-hidden shadow-xl mb-8">
            <div class="px-6 py-4 border-b border-slate-700 font-bold text-lg text-white flex justify-between items-center">
                <span>🖥️ Live Execution & Automation Stream</span>
                <span class="text-xs text-slate-400 font-normal">Auto-refreshing every 5s</span>
            </div>
            <div class="p-6 bg-slate-950 font-mono text-xs text-emerald-400 h-72 overflow-y-auto space-y-1">
                {% for log in logs %}
                    <div>{{ log }}</div>
                {% endfor %}
            </div>
        </div>
    </div>
    <script>
        function triggerClipper() {
            fetch('/api/trigger-clipper', {method: 'POST', headers: {'Authorization': 'Bearer jarvis-local-master-2026'}})
                .then(r => r.json())
                .then(res => { alert(res.message || 'Clipper triggered!'); location.reload(); });
        }
    </script>
</body>
</html>
"""

def run_all_tasks():
    log_action("[Worker] Starting automation sweep (FBA + Trends + Video Clipper)...")
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

    try:
        res3 = subprocess.run("python video_clipper.py", shell=True, capture_output=True, text=True, cwd=os.path.dirname(__file__))
        for line in res3.stdout.splitlines():
            if line.strip(): log_action(f"  [Clipper] {line}")
    except Exception as e:
        log_action(f"[Worker] Video clipper error: {e}")

def background_scheduler():
    time.sleep(5)
    while True:
        log_action("[Scheduler] === Starting Continuous 12-Hour Automation Block ===")
        block_start = time.time()
        while time.time() - block_start < 43200:
            run_all_tasks()
            log_action("[Scheduler] Sweeps complete. Sleeping 2 minutes before next check...")
            time.sleep(120)
            
        log_action("[Scheduler] === 12 Hours Reached. Pausing for 5 minutes for OneDrive sync ===")
        time.sleep(300)

@app.route('/dashboard', methods=['GET'])
def dashboard():
    queues, outputs = get_clipper_status()
    return render_template_string(DASHBOARD_HTML, logs=reversed(EXEC_LOGS), queues=queues, outputs=outputs)

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'online',
        'hostname': os.environ.get('COMPUTERNAME', 'SparePC'),
        'time': datetime.datetime.now().isoformat()
    })

@app.route('/api/trigger-clipper', methods=['POST'])
def trigger_clipper():
    log_action("Immediate video clip sweep requested via Dashboard GUI.")
    threading.Thread(target=run_all_tasks).start()
    return jsonify({'success': True, 'message': 'Video clipping and scan sweep dispatched instantly.'})

if __name__ == '__main__':
    log_action("Starting Trend & Product Scanner on 0.0.0.0:8899...")
    sched_thread = threading.Thread(target=background_scheduler, daemon=True)
    sched_thread.start()
    log_action("24/7 Automation & Video Clipping Daemon initialized with Queue GUI.")
    
    app.run(host='0.0.0.0', port=8899)
