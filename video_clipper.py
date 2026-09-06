"""
24/7 Automated Video Clipping & 9:16 Vertical Cropper Daemon (Runs on Spare PC: 192.168.86.70)
Monitors OneDrive input folders for raw source videos (Mobster movies, police cams, podcasts),
automatically slices them into viral 30-second 9:16 vertical clips, and outputs them ready to post.
"""
import os
import time
import subprocess
import datetime
import glob

VAULT_BASE = r"C:\Users\bclar\OneDrive\Desktop\Jarvis 2.0\04 - Active Projects\Video Clipper"
INPUT_DIR = os.path.join(VAULT_BASE, "Input")
OUTPUT_DIR = os.path.join(VAULT_BASE, "Output")
PROCESSED_DIR = os.path.join(VAULT_BASE, "Processed")

def ensure_dirs():
    for d in [INPUT_DIR, OUTPUT_DIR, PROCESSED_DIR]:
        for sub in ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]:
            os.makedirs(os.path.join(d, sub), exist_ok=True)

def process_videos():
    ensure_dirs()
    print("[Video Clipper] Scanning input folders for new source videos...")
    
    subfolders = ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]
    
    for sub in subfolders:
        in_sub = os.path.join(INPUT_DIR, sub)
        out_sub = os.path.join(OUTPUT_DIR, sub)
        proc_sub = os.path.join(PROCESSED_DIR, sub)
        
        video_files = []
        for ext in ["*.mp4", "*.mov", "*.mkv", "*.avi"]:
            video_files.extend(glob.glob(os.path.join(in_sub, ext)))
            
        for video_path in video_files:
            filename = os.path.basename(video_path)
            name_no_ext, _ = os.path.splitext(filename)
            print(f"[Video Clipper] Found new source video: {filename} in {sub}")
            
            # Generate 30-second clips (e.g. 3 clips per source video at different timestamps: 0s, 60s, 120s)
            timestamps = [0, 60, 120]
            
            for i, ts in enumerate(timestamps, 1):
                output_filename = f"{name_no_ext}_clip_{i}.mp4"
                output_path = os.path.join(out_sub, output_filename)
                
                if os.path.exists(output_path):
                    continue
                    
                print(f"[Video Clipper] Generating 9:16 vertical clip #{i} starting at {ts}s...")
                
                # FFmpeg command: seek to timestamp, take 30s, crop to 9:16 vertical (1080x1920)
                cmd = f'ffmpeg -y -ss {ts} -i "{video_path}" -t 30 -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -c:v libx264 -preset fast -c:a aac "{output_path}"'
                
                try:
                    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=120)
                    if res.returncode == 0:
                        print(f"  -> Saved viral short: {output_path}")
                    else:
                        print(f"  -> FFmpeg error on clip {i}: {res.stderr}")
                except Exception as e:
                    print(f"  -> Exception clipping video: {e}")
                    
            # Move source to processed
            try:
                dest_processed = os.path.join(proc_sub, filename)
                if os.path.exists(dest_processed):
                    os.remove(dest_processed)
                os.rename(video_path, dest_processed)
                print(f"[Video Clipper] Moved source to processed folder: {filename}")
            except Exception as e:
                print(f"Error moving processed file: {e}")

if __name__ == "__main__":
    ensure_dirs()
    print("Starting 24/7 Video Clipping Daemon...")
    while True:
        try:
            process_videos()
        except Exception as e:
            print(f"Daemon error: {e}")
        time.sleep(30) # Check every 30 seconds for new source videos
