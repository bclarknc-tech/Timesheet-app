"""
24/7 Multi-Source Market Trend & Consumer Demand Spotter (Runs on Spare PC: 192.168.86.70)
Aggregates live consumer trends, product launches, and demand signals across multiple public RSS feeds,
and logs new market gaps directly into your Obsidian Vault.
"""
import os
import datetime
import time
import urllib.request
import xml.etree.ElementTree as ET
import json

FEEDS = [
    {"name": "Google Trends US", "url": "https://trends.google.com/trends/trendingsearches/daily/rss?geo=US"},
    {"name": "Product Hunt New Tech", "url": "https://www.producthunt.com/feed"},
    {"name": "GitHub Trending Tech", "url": "https://github.com/trending.atom"}
]

def scan_trends():
    print("[Trend Scanner] Starting multi-source market trend sweep...")
    time.sleep(1)
    
    vault_dir = os.path.expanduser(r"~\OneDrive\Desktop\My Jarvis\04 - Active Projects\Market Trends")
    os.makedirs(vault_dir, exist_ok=True)
    
    history_path = os.path.join(vault_dir, "trend_history.json")
    seen_trends = set()
    if os.path.exists(history_path):
        try:
            with open(history_path, 'r', encoding='utf-8') as f:
                seen_trends = set(json.load(f))
        except:
            pass

    new_insights = []
    
    for feed in FEEDS:
        print(f"[Trend Scanner] Fetching {feed['name']}...")
        req = urllib.request.Request(
            feed['url'],
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
        )
        try:
            with urllib.request.urlopen(req, timeout=8) as response:
                xml_data = response.read()
                root = ET.fromstring(xml_data)
                
                # Handle RSS vs Atom namespaces
                items = root.findall('.//item') or root.findall('.//{http://www.w3.org/2005/Atom}entry')
                for item in items[:10]:
                    title_elem = item.find('title') or item.find('{http://www.w3.org/2005/Atom}title')
                    if title_elem is not None and title_elem.text:
                        title = title_elem.text.strip()
                        if title not in seen_trends:
                            seen_trends.add(title)
                            new_insights.append({
                                'source': feed['name'],
                                'title': title
                            })
        except Exception as e:
            print(f"Error fetching {feed['name']}: {e}")
        time.sleep(1)

    # Save history
    try:
        with open(history_path, 'w', encoding='utf-8') as f:
            json.dump(list(seen_trends)[-500:], f, indent=2) # keep last 500
    except:
        pass

    if not new_insights:
        print("[Trend Scanner] Scan complete. No brand new cross-platform trends in this cycle.")
        return

    date_str = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M")
    report_path = os.path.join(vault_dir, f"Market_Trend_Spotted_{date_str}.md")
    
    # Atomic write (write to temp file then rename)
    temp_path = report_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as f:
        f.write(f"# 📈 New Market Trends & Product Signals — {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n")
        f.write("Aggregated live across Google Trends, Product Hunt, and Developer Markets:\n\n")
        for item in new_insights:
            f.write(f"- **[{item['source']}]** {item['title']}\n")
            
    if os.path.exists(report_path):
        os.remove(report_path)
    os.rename(temp_path, report_path)
    
    print(f"[Trend Scanner] Saved {len(new_insights)} new trend signals to {report_path}")

if __name__ == "__main__":
    scan_trends()
