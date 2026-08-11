from flask import Flask, render_template, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
import os

app = Flask(__name__)

database_url = os.environ.get('DATABASE_URL')
if database_url:
    database_url = database_url.replace('postgres://', 'postgresql://', 1)
    app.config['SQLALCHEMY_DATABASE_URI'] = database_url
else:
    basedir = os.path.abspath(os.path.dirname(__file__))
    app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///' + os.path.join(basedir, 'timesheet.db')

app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)

class Timesheet(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    employee_name = db.Column(db.String(100), nullable=False)
    job_number = db.Column(db.String(20), nullable=False)
    job_name = db.Column(db.String(200), nullable=False)
    hours = db.Column(db.Float, nullable=False)
    description = db.Column(db.Text, nullable=False)
    work_date = db.Column(db.Date, nullable=False)
    date_submitted = db.Column(db.DateTime, default=datetime.utcnow)
    is_billed = db.Column(db.Boolean, default=False)

import json
import os

EMPLOYEES = ['Brian Clark', 'Rolfe Haigler', 'Dylan Williams']

JOBS = []

def load_jobs():
    global JOBS
    json_path = os.path.join(os.path.dirname(__file__), 'jobs.json')

    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            JOBS = json.load(f)
    except Exception as e:
        print(f"Error loading jobs from {json_path}: {e}")
        JOBS = []

load_jobs()

with app.app_context():
    db.create_all()

@app.route('/')
def index():
    return render_template('index.html', employees=EMPLOYEES, jobs=JOBS)

@app.route('/api/jobs')
def get_jobs():
    return jsonify(JOBS)

@app.route('/api/submit', methods=['POST'])
def submit_timesheet():
    from datetime import date
    data = request.json
    try:
        entry = Timesheet(
            employee_name=data['employee_name'],
            job_number=data['job_number'],
            job_name=data['job_name'],
            hours=float(data['hours']),
            description=data['description'],
            work_date=datetime.strptime(data['date'], '%Y-%m-%d').date()
        )
        db.session.add(entry)
        db.session.commit()
        print(f"[SUBMIT] Success - ID {entry.id}, DB: {app.config['SQLALCHEMY_DATABASE_URI'][:50]}")
        return jsonify({'success': True, 'id': entry.id})
    except Exception as e:
        print(f"[SUBMIT] Error: {str(e)}, DB: {app.config['SQLALCHEMY_DATABASE_URI'][:50]}")
        return jsonify({'success': False, 'error': str(e)}), 400

@app.route('/admin')
def admin():
    return render_template('admin.html')

@app.route('/api/toggle-bill/<int:entry_id>', methods=['POST'])
def toggle_bill(entry_id):
    try:
        entry = Timesheet.query.get(entry_id)
        entry.is_billed = not entry.is_billed
        db.session.commit()
        return jsonify({'success': True, 'is_billed': entry.is_billed})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400

@app.route('/api/delete/<int:entry_id>', methods=['DELETE'])
def delete_entry(entry_id):
    try:
        entry = Timesheet.query.get(entry_id)
        if not entry:
            return jsonify({'success': False, 'error': 'Entry not found'}), 404
        db.session.delete(entry)
        db.session.commit()
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400

@app.route('/api/report', methods=['GET'])
def get_report():
    job_number = request.args.get('job_number')
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    unbilled_only = request.args.get('unbilled_only', 'false').lower() == 'true'

    query = Timesheet.query

    if job_number:
        query = query.filter_by(job_number=job_number)

    if start_date:
        query = query.filter(Timesheet.work_date >= datetime.fromisoformat(start_date).date())

    if end_date:
        query = query.filter(Timesheet.work_date <= datetime.fromisoformat(end_date).date())

    if unbilled_only:
        query = query.filter_by(is_billed=False)

    entries = query.all()
    print(f"[REPORT] Found {len(entries)} entries, DB: {app.config['SQLALCHEMY_DATABASE_URI'][:50]}")

    result = []
    total_hours = 0
    for entry in entries:
        result.append({
            'id': entry.id,
            'employee': entry.employee_name,
            'job_number': entry.job_number,
            'job_name': entry.job_name,
            'hours': entry.hours,
            'date': entry.work_date.strftime('%Y-%m-%d'),
            'description': entry.description,
            'is_billed': entry.is_billed
        })
        total_hours += entry.hours

    return jsonify({'entries': result, 'total_hours': total_hours})

if __name__ == '__main__':
    load_jobs()
    with app.app_context():
        db.create_all()
    app.run(debug=True, port=5000)
