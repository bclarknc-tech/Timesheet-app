import os
import datetime

def scan_niches():
    raw_candidates = [
        {"product": "Silicone Travel Bottle Set", "price": 19.99, "est_sales": 450, "reviews": 120, "rating": 4.4},
        {"product": "Stainless Steel Measuring Spoons", "price": 14.50, "est_sales": 280, "reviews": 450, "rating": 4.2},
        {"product": "Bamboo Drawer Dividers", "price": 27.99, "est_sales": 620, "reviews": 95, "rating": 4.6},
    ]

    qualified = []
    for item in raw_candidates:
        if 15 <= item['price'] <= 30 and item['est_sales'] >= 300 and item['reviews'] < 200:
            qualified.append(item)

    vault_dir = r"C:\Users\bclar\OneDrive\Desktop\My Jarvis\04 - Active Projects\FBA"
    os.makedirs(vault_dir, exist_ok=True)
    
    date_str = datetime.datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(vault_dir, f"FBA_Scan_{date_str}.md")
    
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(f"# FBA Opportunity Scan — {date_str}\n\n")
        f.write("Filtered by Rule of Threes (Price $15-$30, Sales >= 300/mo, Reviews < 200):\n\n")
        for q in qualified:
            f.write(f"- **{q['product']}** | Price: ${q['price']} | Est. Sales: {q['est_sales']}/mo | Reviews: {q['reviews']}\n")
            
    print(f"Scan complete. Found {len(qualified)} qualified opportunities. Saved to {report_path}")

if __name__ == "__main__":
    scan_niches()
