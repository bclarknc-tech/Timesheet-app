"""
24/7 Social & Forum Trend-Spotter (Runs on Spare PC: 192.168.86.70)
Scrapes public demand signals from Reddit, product forums, and consumer search gaps,
and drops daily Product Gap Reports straight into your Obsidian Vault.
"""
import os
import datetime
import urllib.request
import json
import time

TARGET_SUBREDDITS = [
    "DidntKnowIWantedThat",
    "HelpMeFind",
    "AmazonFBA",
    "Entrepreneur",
    "ProductPorn"
]

KEYWORDS = [
    "wish there was",
    "looking for a good",
    "always breaks",
    "can't find",
    "where can i buy",
    "terrible quality",
    "need a better"
]

def scan_trends():
    vault_dir = r"C:\Users\bclar\OneDrive\Desktop\My Jarvis\04 - Active Projects\Market Trends"
    os.makedirs(vault_dir, exist_ok=True)
    
    insights = []
    
    for sub in TARGET_SUBREDDITS:
        url = f"https://www.reddit.com/r/{sub}/hot.json?limit=25"
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'}
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                data = json.loads(response.read().decode('utf-8'))
                posts = data.get('data', {}).get('children', [])
                
                for post in posts:
                    pdata = post.get('data', {})
                    title = pdata.get('title', '')
                    selftext = pdata.get('selftext', '')
                    score = pdata.get('score', 0)
                    url = f"https://reddit.com{pdata.get('permalink', '')}"
                    
                    combined_text = (title + " " + selftext).lower()
                    
                    # Check for demand or pain point keywords
                    matched_keyword = next((kw for kw in KEYWORDS if kw in combined_text), None)
                    if matched_keyword or score > 500:
                        insights.append({
                            'subreddit': sub,
                            'title': title,
                            'score': score,
                            'url': url,
                            'signal': matched_keyword or 'High Engagement'
                        })
        except Exception as e:
            print(f"Error fetching r/{sub}: {e}")
        time.sleep(1) # Be polite to public rate limits
        
    # Sort by engagement score
    insights = sorted(insights, key=lambda x: x['score'], reverse=True)[:15]
    
    date_str = datetime.datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(vault_dir, f"Trend_Report_{date_str}.md")
    
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(f"# 🔍 Market Gap & Trend Report — {date_str}\n\n")
        f.write("Scraped from high-intent consumer forums and product communities (Reddit public feeds).\n\n")
        
        if insights:
            for item in insights:
                f.write(f"### [{item['title']}]({item['url']})\n")
                f.write(f"- **Community:** r/{item['subreddit']} | **Engagement Score:** ⬆️ {item['score']}\n")
                f.write(f"- **Signal Detected:** *{item['signal']}* 🎯\n\n")
        else:
            f.write("No high-intent demand signals detected in this cycle.\n")
            
    print(f"Trend scan complete. Saved {len(insights)} consumer insights to {report_path}")

if __name__ == "__main__":
    scan_trends()
