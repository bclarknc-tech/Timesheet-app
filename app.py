from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
from functools import wraps
import os
import json

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'timesheet-admin-secret-2026')
ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD', 'admin')

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

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            if request.path.startswith('/api/'):
                return jsonify({'error': 'Unauthorized access'}), 401
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

@app.route('/')
def index():
    return render_template('index.html', employees=EMPLOYEES, jobs=JOBS)

@app.route('/login', methods=['GET', 'POST'])
def login():
    error = None
    if request.method == 'POST':
        password = request.form.get('password')
        if password == ADMIN_PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('admin'))
        else:
            error = 'Incorrect password. Try again.'
    return render_template('login.html', error=error)

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/api/jobs')
def get_jobs():
    return jsonify(JOBS)

@app.route('/api/submit', methods=['POST'])
def submit_timesheet():
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
        return jsonify({'success': True, 'id': entry.id})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400

@app.route('/admin')
@login_required
def admin():
    return render_template('admin.html', jobs_count=len(JOBS))

@app.route('/admin/upload-jobs', methods=['POST'])
@login_required
def upload_jobs():
    if 'file' not in request.files:
        return jsonify({'success': False, 'error': 'No file uploaded'}), 400
    file = request.files['file']
    if not file.filename.lower().endswith(('.xlsx', '.xls')):
        return jsonify({'success': False, 'error': 'File must be an Excel file (.xlsx or .xls)'}), 400
    
    try:
        import openpyxl
        wb = openpyxl.load_workbook(file, data_only=True)
        sheet = wb.active
        
        new_jobs = []
        for row in sheet.iter_rows(values_only=True):
            if not row or len(row) < 2:
                continue
            col0 = str(row[0]).strip() if row[0] is not None else ''
            col1 = str(row[1]).strip() if row[1] is not None else ''
            
            # Skip header rows
            if col0.lower() in ['job', 'job number', 'job #', 'number', '#', 'job_number'] or col1.lower() in ['name', 'job name', 'description', 'job_name']:
                continue
            
            if col0 and col1 and col0.lower() != 'none' and col1.lower() != 'none':
                new_jobs.append({'number': col0, 'name': col1})
        
        if not new_jobs:
            return jsonify({'success': False, 'error': 'No valid job rows found in Excel file'}), 400
            
        json_path = os.path.join(os.path.dirname(__file__), 'jobs.json')
        with open(json_path, 'w', encoding='utf-8') as f:
            json.dump(new_jobs, f, indent=2)
            
        load_jobs()
        return jsonify({'success': True, 'count': len(new_jobs)})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/toggle-bill/<int:entry_id>', methods=['POST'])
@login_required
def toggle_bill(entry_id):
    try:
        entry = Timesheet.query.get(entry_id)
        if not entry:
            return jsonify({'success': False, 'error': 'Entry not found'}), 404
        entry.is_billed = not entry.is_billed
        db.session.commit()
        return jsonify({'success': True, 'is_billed': entry.is_billed})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400

@app.route('/api/delete/<int:entry_id>', methods=['DELETE'])
@login_required
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
@login_required
def get_report():
    employee_name = request.args.get('employee_name')
    job_number = request.args.get('job_number')
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    unbilled_only = request.args.get('unbilled_only', 'false').lower() == 'true'
    report_type = request.args.get('report_type', 'flat')

    query = Timesheet.query

    if employee_name:
        query = query.filter_by(employee_name=employee_name)

    if job_number:
        query = query.filter_by(job_number=job_number)

    if start_date:
        query = query.filter(Timesheet.work_date >= datetime.fromisoformat(start_date).date())

    if end_date:
        query = query.filter(Timesheet.work_date <= datetime.fromisoformat(end_date).date())

    if unbilled_only:
        query = query.filter_by(is_billed=False)

    entries = query.all()

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

    grouped = None
    if report_type == 'by_employee':
        grouped = {}
        for entry in result:
            emp = entry['employee']
            if emp not in grouped:
                grouped[emp] = {'entries': [], 'total_hours': 0}
            grouped[emp]['entries'].append(entry)
            grouped[emp]['total_hours'] += entry['hours']
    elif report_type == 'by_job':
        grouped = {}
        for entry in result:
            job = entry['job_number']
            if job not in grouped:
                grouped[job] = {'entries': [], 'total_hours': 0, 'job_name': entry['job_name']}
            grouped[job]['entries'].append(entry)
            grouped[job]['total_hours'] += entry['hours']
    elif report_type == 'by_date':
        grouped = {}
        for entry in result:
            date = entry['date']
            if date not in grouped:
                grouped[date] = {'entries': [], 'total_hours': 0}
            grouped[date]['entries'].append(entry)
            grouped[date]['total_hours'] += entry['hours']

    return jsonify({
        'entries': result,
        'total_hours': round(total_hours, 2),
        'grouped': grouped,
        'report_type': report_type
    })

if __name__ == '__main__':
    load_jobs()
    with app.app_context():
        db.create_all()
    app.run(debug=True, port=5000)
