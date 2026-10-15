from flask import Flask, render_template, request, jsonify, session, redirect, url_for, make_response
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
from functools import wraps
from io import BytesIO
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
import os
import json
import time

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'timesheet-admin-secret-2026')
ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD', 'admin')

def normalize_database_url(url):
    """Accept both postgres:// and postgresql:// and use the psycopg v3 driver.

    Render has issued both schemes. A bare postgresql:// URL asks SQLAlchemy
    for the psycopg module, not psycopg2.
    """
    if not url:
        return url
    scheme, sep, rest = url.partition('://')
    if not sep:
        return url
    scheme_name = scheme.lower()
    if scheme_name in ('postgres', 'postgresql'):
        scheme_name = 'postgresql+psycopg'
    return scheme_name + '://' + rest

database_url = os.environ.get('DATABASE_URL')
if database_url:
    app.config['SQLALCHEMY_DATABASE_URI'] = normalize_database_url(database_url)
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

class Job(db.Model):
    """Job-number catalog used by the timesheet autofill. Separate from timesheet entries."""
    __tablename__ = 'job_catalog'
    id = db.Column(db.Integer, primary_key=True)
    number = db.Column(db.String(128), nullable=False, unique=True, index=True)
    name = db.Column(db.Text, nullable=False)
    sort_order = db.Column(db.Integer, nullable=False, default=0)

class JobCatalogMeta(db.Model):
    """One row describing where the current catalog came from and when."""
    __tablename__ = 'job_catalog_meta'
    id = db.Column(db.Integer, primary_key=True)
    source = db.Column(db.String(32), nullable=False, default='json')
    updated_epoch = db.Column(db.Float, nullable=False, default=0)
    source_mtime = db.Column(db.Float, nullable=True)

EMPLOYEES = ['Brian Clark', 'Rolfe Haigler', 'Dylan Williams']
DEFAULT_MASTER_JOB_FILE = r"C:\Users\bclar\OneDrive - segeomatics.com\2009 - SGG JOBS\Job List - 09302009.xls"
NUMBER_HEADERS = {
    'job number', 'job #', 'job no', 'job no.', 'job num', 'jobnumber', 'number',
}
NAME_HEADERS = {
    'job name', 'jobname', 'name', 'project', 'project name',
}
_last_master_check = 0

def master_job_path():
    return os.environ.get('MASTER_JOB_FILE', DEFAULT_MASTER_JOB_FILE)

def _header_key(value):
    text_value = normalize_job_name(value).lower().replace('_', ' ')
    return ' '.join(text_value.replace('#', ' # ').split())

def normalize_job_number(value):
    import pandas as pd
    if value is None:
        return ''
    if not isinstance(value, str):
        try:
            if pd.isna(value):
                return ''
        except TypeError:
            pass
    if isinstance(value, str):
        text_value = value.strip()
        if not text_value or text_value.lower() == 'nan':
            return ''
        if text_value.endswith('.0'):
            head = text_value[:-2].strip()
            if head.lstrip('-').isdigit():
                return head
        return text_value
    try:
        number = float(value)
    except (TypeError, ValueError):
        text_value = str(value).strip()
        return '' if not text_value or text_value.lower() == 'nan' else text_value
    if number.is_integer():
        return str(int(number))
    text_value = str(value).strip()
    return '' if text_value.lower() == 'nan' else text_value

def normalize_job_name(value):
    import pandas as pd
    if value is None:
        return ''
    if not isinstance(value, str):
        try:
            if pd.isna(value):
                return ''
        except TypeError:
            pass
    text_value = str(value).strip()
    if not text_value or text_value.lower() == 'nan':
        return ''
    return text_value

def excel_engine_for_bytes(raw, filename):
    if raw.startswith(b'\xD0\xCF\x11\xE0'):
        return 'xlrd'
    if raw.startswith(b'PK\x03\x04'):
        return 'openpyxl'
    ext = os.path.splitext(filename or '')[1].lower()
    if ext == '.xls':
        return 'xlrd'
    if ext in ('.xlsx', '.xlsm'):
        return 'openpyxl'
    return None

def find_job_columns(df):
    specific_numbers = {'job number', 'job #', 'job no', 'job no.', 'job num', 'jobnumber'}
    specific_names = {'job name', 'jobname', 'project name'}
    limit = min(len(df), 40)
    for index in range(limit):
        keys = [_header_key(cell) for cell in df.iloc[index].tolist()]
        num_candidates = [n for n, key in enumerate(keys) if key in NUMBER_HEADERS]
        name_candidates = [n for n, key in enumerate(keys) if key in NAME_HEADERS]
        if not num_candidates or not name_candidates:
            continue
        num_idx = sorted(num_candidates, key=lambda n: (0 if keys[n] in specific_numbers else 1, n))[0]
        name_idx = sorted(name_candidates, key=lambda n: (0 if keys[n] in specific_names else 1, n))[0]
        if num_idx != name_idx:
            return index, num_idx, name_idx
    return None, 0, 1

def jobs_from_dataframe(df):
    if df is None or getattr(df, 'empty', True) or len(df.columns) < 2:
        return []
    header_idx, num_col, name_col = find_job_columns(df)
    start = header_idx + 1 if header_idx is not None else 0
    found = {}
    order = []
    for index in range(start, len(df)):
        row = df.iloc[index]
        if num_col >= len(row) or name_col >= len(row):
            continue
        number = normalize_job_number(row.iloc[num_col])
        name = normalize_job_name(row.iloc[name_col])
        if not number or not name:
            continue
        if number.lower() in NUMBER_HEADERS or name.lower() in NAME_HEADERS:
            continue
        if number not in found:
            order.append(number)
        found[number] = name
    return [{'number': number, 'name': found[number]} for number in order]

def parse_job_excel(source, filename=None):
    import pandas as pd
    if isinstance(source, (bytes, bytearray)):
        raw = bytes(source)
        name = filename or ''
    elif isinstance(source, str):
        name = filename or source
        with open(source, 'rb') as handle:
            raw = handle.read()
    else:
        name = filename or getattr(source, 'filename', '') or ''
        raw = source.read()
    if not raw:
        return []
    engine = excel_engine_for_bytes(raw, name)
    bio = BytesIO(raw)
    read_kwargs = {'header': None, 'sheet_name': None}
    if engine:
        read_kwargs['engine'] = engine
    try:
        sheets = pd.read_excel(bio, **read_kwargs)
    except Exception:
        if not engine:
            raise
        bio.seek(0)
        sheets = pd.read_excel(bio, header=None, sheet_name=None)
    if not isinstance(sheets, dict):
        sheets = {'Sheet1': sheets}
    best = []
    for frame in sheets.values():
        parsed = jobs_from_dataframe(frame)
        if len(parsed) > len(best):
            best = parsed
    return best

def load_jobs_json():
    json_path = os.path.join(os.path.dirname(__file__), 'jobs.json')
    try:
        with open(json_path, 'r', encoding='utf-8') as handle:
            payload = json.load(handle)
    except Exception as exc:
        print(f"Error loading jobs from {json_path}: {exc}")
        return []
    jobs = []
    seen = set()
    if not isinstance(payload, list):
        return []
    for item in payload:
        if not isinstance(item, dict):
            continue
        number = normalize_job_number(item.get('number'))
        name = normalize_job_name(item.get('name'))
        if not number or not name or number in seen:
            continue
        seen.add(number)
        jobs.append({'number': number, 'name': name})
    return jobs

def get_job_list():
    rows = Job.query.order_by(Job.sort_order.asc(), Job.id.asc()).all()
    return [{'number': row.number, 'name': row.name} for row in rows]

def save_job_catalog(jobs, source, source_mtime=None):
    """Replace the job catalog only. Timesheet rows are never touched."""
    for row in Job.query.all():
        db.session.delete(row)
    db.session.flush()
    for index, job in enumerate(jobs):
        db.session.add(Job(number=job['number'], name=job['name'], sort_order=index))
    meta = db.session.get(JobCatalogMeta, 1)
    if meta is None:
        meta = JobCatalogMeta(id=1)
        db.session.add(meta)
    meta.source = source
    meta.updated_epoch = time.time()
    meta.source_mtime = source_mtime
    db.session.commit()
    print(f"Saved {len(jobs)} jobs to the database catalog (source={source})")

def _with_catalog_lock(fn):
    dialect = db.session.get_bind().dialect.name
    locked = dialect == 'postgresql'
    if locked:
        db.session.execute(text('SELECT pg_advisory_lock(:key)'), {'key': 874521})
    try:
        return fn()
    finally:
        if locked:
            db.session.execute(text('SELECT pg_advisory_unlock(:key)'), {'key': 874521})
            db.session.commit()

def seed_job_catalog_if_empty():
    def _seed():
        if Job.query.count() > 0:
            return
        jobs = []
        source = 'json'
        source_mtime = None
        master_path = master_job_path()
        if master_path and os.path.exists(master_path):
            try:
                jobs = parse_job_excel(master_path)
                source = 'master'
                source_mtime = os.path.getmtime(master_path)
            except Exception as exc:
                print(f"Error reading master Excel file {master_path}: {exc}")
                jobs = []
        if not jobs:
            jobs = load_jobs_json()
            source = 'json'
            source_mtime = None
        if jobs:
            save_job_catalog(jobs, source=source, source_mtime=source_mtime)
    try:
        _with_catalog_lock(_seed)
    except IntegrityError:
        db.session.rollback()

def maybe_sync_master_job_file():
    """Keep the OneDrive master workbook sync, without clobbering a newer admin upload."""
    global _last_master_check
    now = time.time()
    if now - _last_master_check < 60:
        return
    _last_master_check = now
    master_path = master_job_path()
    if not master_path or not os.path.exists(master_path):
        return
    try:
        mtime = os.path.getmtime(master_path)
    except OSError:
        return
    meta = db.session.get(JobCatalogMeta, 1)
    if meta and meta.source == 'master' and meta.source_mtime == mtime:
        return
    if meta and meta.source == 'upload' and (meta.updated_epoch or 0) > mtime:
        return
    try:
        jobs = parse_job_excel(master_path)
    except Exception as exc:
        print(f"Error reading master Excel file {master_path}: {exc}")
        return
    if jobs:
        save_job_catalog(jobs, source='master', source_mtime=mtime)

def _no_store(response):
    response.headers['Cache-Control'] = 'no-store, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['X-DB-Driver'] = db.engine.dialect.driver
    return response

with app.app_context():
    db.create_all()
    seed_job_catalog_if_empty()

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
    maybe_sync_master_job_file()
    response = make_response(render_template('index.html', employees=EMPLOYEES, jobs=get_job_list()))
    return _no_store(response)

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
    maybe_sync_master_job_file()
    return _no_store(jsonify(get_job_list()))

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
    maybe_sync_master_job_file()
    jobs = get_job_list()
    return render_template('admin.html', jobs_count=len(jobs), employees=EMPLOYEES)

@app.route('/admin/upload-jobs', methods=['POST'])
@login_required
def upload_jobs():
    if 'file' not in request.files:
        return jsonify({'success': False, 'error': 'No file uploaded'}), 400
    file = request.files['file']
    if not file.filename.lower().endswith(('.xlsx', '.xls')):
        return jsonify({'success': False, 'error': 'File must be an Excel file (.xlsx or .xls)'}), 400
    
    try:
        new_jobs = parse_job_excel(file, filename=file.filename)
        if not new_jobs:
            return jsonify({
                'success': False,
                'error': 'No valid job rows found. Expected columns named Job Number and Job Name.'
            }), 400
        save_job_catalog(new_jobs, source='upload')
        return jsonify({'success': True, 'count': len(new_jobs)})
    except Exception as e:
        db.session.rollback()
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
    app.run(debug=True, port=5000)
