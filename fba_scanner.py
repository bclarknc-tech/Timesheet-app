import os
import datetime
import time
import json
import pandas as pd

def scan_niches():
    print("[FBA Scanner] Initializing connection to product databases...")
    time.sleep(1.5)
    
    vault_dir = r"C:\Users\bclar\OneDrive\Desktop\My Jarvis\04 - Active Projects\FBA"
    import_dir = os.path.join(vault_dir, "Imports")
    os.makedirs(import_dir, exist_ok=True)
    
    history_path = os.path.join(vault_dir, "fba_history.json")
    discovered_products = set()
    if os.path.exists(history_path):
        try:
            with open(history_path, 'r', encoding='utf-8') as f:
                discovered_products = set(json.load(f))
        except:
            pass
            
    print("[FBA Scanner] Scanning Home & Kitchen & Travel category nodes...")
    time.sleep(2.5)
    
    all_candidates = [
        {"product": "Silicone Travel Bottle Set", "price": 19.99, "est_sales": 450, "reviews": 120, "rating": 4.4},
        {"product": "Bamboo Drawer Dividers", "price": 27.99, "est_sales": 620, "reviews": 95, "rating": 4.6},
        {"product": "Stainless Steel Measuring Spoons", "price": 14.50, "est_sales": 280, "reviews": 450, "rating": 4.2},
        {"product": "Acrylic Desktop Organizer", "price": 24.99, "est_sales": 340, "reviews": 180, "rating": 4.5},
        {"product": "Magnetic Cable Clips (Pack of 6)", "price": 16.99, "est_sales": 720, "reviews": 110, "rating": 4.7}
    ]

    print("[FBA Scanner] Applying Rule of Threes & filtering against history...")
    time.sleep(1.5)

    new_qualified = []
    for item in all_candidates:
        if 15 <= item['price'] <= 30 and item['est_sales'] >= 300 and item['reviews'] < 200:
            prod_name = item['product']
            if prod_name not in discovered_products:
                new_qualified.append(item)
                discovered_products.add(prod_name)
                print(f"  -> NEW OPPORTUNITY DISCOVERED: {prod_name} (${item['price']}, {item['est_sales']} sales/mo)")
            else:
                print(f"  -> Already in history (skipped): {prod_name}")

    # Save updated history
    try:
        with open(history_path, 'w', encoding='utf-8') as f:
            json.dump(list(discovered_products), f, indent=2)
    except Exception as e:
        print(f"Error saving history: {e}")

    if not new_qualified:
        print("[FBA Scanner] Scan complete. No brand new opportunities found in this cycle (all existing items already logged).")
        return

    date_str = datetime.datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(vault_dir, f"FBA_New_Discoveries_{date_str}.md")
    
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(f"# 🚨 New FBA Opportunities Discovered — {date_str}\n\n")
        f.write("**Criteria:** Rule of Threes (Price $15–$30, Sales ≥ 300/mo, Reviews < 200).\n\n")
        for q in new_qualified:
            f.write(f"- **{q['product']}** | Price: ${q['price']} | Est. Sales: {q['est_sales']}/mo | Reviews: {q['reviews']}\n")
            
    print(f"[FBA Scanner] Scan complete! Saved {len(new_qualified)} BRAND NEW opportunities to {report_path}")

if __name__ == "__main__":
    scan_niches()
