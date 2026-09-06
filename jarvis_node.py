"""
Jarvis Master Node Daemon (Runs on Spare PC: 192.168.86.70)
Provides a secure local API for task execution, FBA scrapers, app building, and Geomatics automation.
"""
from flask import Flask, request, jsonify
import subprocess
import os
import datetime

app = Flask(__name__)
SECRET_TOKEN = "jarvis-local-master-2026"

def verify_auth():
    auth = request.headers.get('Authorization', '')
    if auth != f"Bearer {SECRET_TOKEN}":
        return False
    return True

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'online',
        'hostname': os.environ.get('COMPUTERNAME', 'SparePC'),
        'time': datetime.datetime.now().isoformat()
    })

@app.route('/exec', methods=['POST'])
def execute_command():
    if not verify_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    data = request.json or {}
    cmd = data.get('command')
    if not cmd:
        return jsonify({'error': 'No command provided'}), 400
    
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300, cwd=data.get('cwd', None))
        return jsonify({
            'success': True,
            'exit_code': result.returncode,
            'stdout': result.stdout,
            'stderr': result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/fba-run', methods=['POST'])
def run_fba_task():
    if not verify_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    # Trigger FBA scraper or analysis
    return jsonify({'success': True, 'message': 'FBA task initiated on master node'})

if __name__ == '__main__':
    print("Starting Jarvis Master Node on 0.0.0.0:8899...")
    app.run(host='0.0.0.0', port=8899)
