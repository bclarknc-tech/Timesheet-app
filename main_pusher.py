"""
Main PC Auto-Pusher (Runs on Main PC: OfficePC)
Explicitly monitors M:\Video Clipper\Input\ on the Main PC and automatically pushes any new raw source videos
over the local network to the Spare PC (192.168.86.70:8899) for automated clipping.
"""
import os
import time
import requests
import glob

LOCAL_BASE = r"M:\Video Clipper\Input"
SPARE_PC_URL = "http://192.168.86.70:8899/upload-video"
SECRET_TOKEN = "jarvis-local-master-2026"

def check_and_push():
    if not os.path.exists(LOCAL_BASE):
        print(f"[Pusher] Waiting for Main PC folder: {LOCAL_BASE}")
        return
        
    subfolders = ["TikTok_Mobsters", "YouTube_PoliceCams", "General"]
    
    for sub in subfolders:
        sub_path = os.path.join(LOCAL_BASE, sub)
        if not os.path.exists(sub_path):
            continue
            
        video_files = []
        for ext in ["*.mp4", "*.mov", "*.mkv", "*.avi"]:
            video_files.extend(glob.glob(os.path.join(sub_path, ext)))
            
        for video_path in video_files:
            filename = os.path.basename(video_path)
            print(f"[Pusher] Found new file in Main PC M: drive: {filename} ({sub})")
            
            try:
                with open(video_path, 'rb') as f:
                    files = {'file': (filename, f)}
                    data = {'subfolder': sub}
                    headers = {'Authorization': f"Bearer {SECRET_TOKEN}"}
                    
                    print(f"[Pusher] Uploading {filename} to Spare PC over local network...")
                    res = requests.post(SPARE_PC_URL, files=files, data=data, headers=headers, timeout=300)
                    
                    if res.status_code == 200 and res.json().get('success'):
                        print(f"[Pusher] Successfully pushed {filename}! Archiving on M: drive...")
                        archive_dir = r"M:\Video Clipper\Processed"
                        os.makedirs(os.path.join(archive_dir, sub), exist_ok=True)
                        dest = os.path.join(archive_dir, sub, filename)
                        if os.path.exists(dest):
                            os.remove(dest)
                        os.rename(video_path, dest)
                    else:
                        print(f"[Pusher] Error response from spare PC: {res.text}")
            except Exception as e:
                print(f"[Pusher] Exception pushing {filename}: {e}")

if __name__ == "__main__":
    print("==================================================")
    print(" Main PC Auto-Pusher Started")
    print(f" Explicitly Monitoring Main PC: {LOCAL_BASE}")
    print("==================================================")
    
    os.makedirs(r"M:\Video Clipper\Processed", exist_ok=True)
    
    while True:
        try:
            check_and_push()
        except Exception as e:
            print(f"Pusher loop error: {e}")
        time.sleep(10)
