from flask import Flask, render_template, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
import os

app = Flask(__name__)
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
    date_submitted = db.Column(db.DateTime, default=datetime.utcnow)
    is_billed = db.Column(db.Boolean, default=False)

EMPLOYEES = ['Brian Clark', 'Rolf Hagler', 'Dylan Williams']

JOBS = []

def load_jobs():
    global JOBS
    import csv
    import os

    csv_path = r'C:\Users\bclar\OneDrive - segeomatics.com\2009 - SGG JOBS\Job List - 09302009 - C.csv'

    if os.path.exists(csv_path):
        try:
            with open(csv_path, 'r', encoding='utf-8') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    if row and row.get('Job Number') and row.get('Job Name'):
                        job_num = row['Job Number'].strip()
                        job_name = row['Job Name'].strip()
                        if job_num and job_name:
                            JOBS.append({
                                'number': job_num,
                                'name': job_name
                            })
        except Exception as e:
            print(f"Error loading jobs: {e}")
            JOBS = []
    else:
        print(f"CSV not found at {csv_path}, using empty job list")

@app.route('/')
def index():
    return render_template('index.html', employees=EMPLOYEES, jobs=JOBS)

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
            description=data['description']
        )
        db.session.add(entry)
        db.session.commit()
        return jsonify({'success': True, 'id': entry.id})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400

@app.route('/admin')
def admin():
    entries = Timesheet.query.all()
    return render_template('admin.html', entries=entries)

@app.route('/api/toggle-bill/<int:entry_id>', methods=['POST'])
def toggle_bill(entry_id):
    try:
        entry = Timesheet.query.get(entry_id)
        entry.is_billed = not entry.is_billed
        db.session.commit()
        return jsonify({'success': True, 'is_billed': entry.is_billed})
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
        query = query.filter(Timesheet.date_submitted >= datetime.fromisoformat(start_date))

    if end_date:
        query = query.filter(Timesheet.date_submitted <= datetime.fromisoformat(end_date))

    if unbilled_only:
        query = query.filter_by(is_billed=False)

    entries = query.all()

    result = []
    total_hours = 0
    for entry in entries:
        result.append({
            'employee': entry.employee_name,
            'job_number': entry.job_number,
            'job_name': entry.job_name,
            'hours': entry.hours,
            'date': entry.date_submitted.strftime('%Y-%m-%d'),
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
