"""
24/7 Autonomous Video Clipping Daemon (Runs on Spare PC: 192.168.86.70)
Monitors local OneDrive Vault path (Jarvis 2.0\Video Clipper) for raw source video files,
automatically slices them into viral 30-second 9:16 vertical clips, and deposits them into Output/.
Requires zero network shares — OneDrive handles all file syncing automatically in the background.
"""
import os
import time
import subprocess
import datetime
import glob

# Local OneDrive Vault path (automatically synced across both PCs by OneDrive)
VAULT_BASE = r"C:\Users\bclar\OneDrive\Desktop\Jarvis 2.0\Video Clipper"
INPUT_DIR = os.path.join(VAULT_BASE, "Input")
OUTPUT_DIR = os.path.join(VAULT_BASE, "Output")
PROCESSED_DIR = os.path.join(VAULT_BASE, "Processed")

def ensure_dirs():
    for d in [INPUT_DIR, OUTPUT_DIR, PROCESSED_DIR]:
        for sub in ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]:
            os.makedirs(os.path.join(d, sub), exist_ok=True)

def process_videos():
    ensure_dirs()
    subfolders = ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]
    
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
            print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [Video Clipper] Found new source video: {filename} in {sub}")
            
            timestamps = [0, 60, 120]
            
            for i, ts in enumerate(timestamps, 1):
                output_filename = f"{name_no_ext}_clip_{i}.mp4"
                output_path = os.path.join(out_sub, output_filename)
                
                if os.path.exists(output_path):
                    continue
                    
                print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [Video Clipper] Generating 9:16 vertical clip #{i} starting at {ts}s...")
                
                cmd = f'ffmpeg -y -ss {ts} -i "{video_path}" -t 30 -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -c:v libx264 -preset fast -c:a aac "{output_path}"'
                
                try:
                    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=120)
                    if res.returncode == 0:
                        print(f"  -> Saved viral short: {output_path}")
                    else:
                        print(f"  -> FFmpeg error on clip {i}: {res.stderr}")
                except Exception as e:
                    print(f"  -> Exception clipping video: {e}")
                    
            try:
                dest_processed = os.path.join(proc_sub, filename)
                if os.path.exists(dest_processed):
                    os.remove(dest_processed)
                os.rename(video_path, dest_processed)
                print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] [Video Clipper] Moved source to processed folder: {filename}")
            except Exception as e:
                print(f"Error moving processed file: {e}")

if __name__ == "__main__":
    ensure_dirs()
    print(f"==================================================")
    print(f" 24/7 Autonomous OneDrive Video Clipper Daemon")
    print(f" Monitoring Vault: {INPUT_DIR}")
    print(f"==================================================")
    
    while True:
        try:
            process_videos()
        except Exception as e:
            print(f"Daemon error: {e}")
        time.sleep(30)
