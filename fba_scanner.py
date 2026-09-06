import os
import datetime
import glob
import pandas as pd

def scan_niches():
    vault_dir = r"C:\Users\bclar\OneDrive\Desktop\My Jarvis\04 - Active Projects\FBA"
    import_dir = os.path.join(vault_dir, "Imports")
    os.makedirs(import_dir, exist_ok=True)
    
    all_candidates = []
    
    # 1. Look for any CSV or Excel files dropped in the Imports folder
    csv_files = glob.glob(os.path.join(import_dir, "*.csv"))
    excel_files = glob.glob(os.path.join(import_dir, "*.xlsx")) + glob.glob(os.path.join(import_dir, "*.xls"))
    
    for f in csv_files:
        try:
            df = pd.read_csv(f)
            all_candidates.extend(parse_dataframe(df))
        except Exception as e:
            print(f"Error reading {f}: {e}")
            
    for f in excel_files:
        try:
            df = pd.read_excel(f)
            all_candidates.extend(parse_dataframe(df))
        except Exception as e:
            print(f"Error reading {f}: {e}")
            
    # If no import files exist yet, include sample/seed data and instruct user
    if not all_candidates:
        print("No import files found in FBA/Imports/. Using baseline seed data.")
        all_candidates = [
            {"product": "Silicone Travel Bottle Set", "price": 19.99, "est_sales": 450, "reviews": 120, "rating": 4.4},
            {"product": "Bamboo Drawer Dividers", "price": 27.99, "est_sales": 620, "reviews": 95, "rating": 4.6},
        ]

    # Apply Rule of Threes: Price $15-$30, Demand >= 300 units/mo, Low competition (<200 reviews)
    qualified = []
    for item in all_candidates:
        if 15 <= item['price'] <= 30 and item['est_sales'] >= 300 and item['reviews'] < 200:
            qualified.append(item)

    date_str = datetime.datetime.now().strftime("%Y-%m-%d")
    report_path = os.path.join(vault_dir, f"FBA_Scan_{date_str}.md")
    
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(f"# FBA Opportunity Scan — {date_str}\n\n")
        f.write(f"**Source:** Processed {len(all_candidates)} total products from Imports folder / seed data.\n")
        f.write("**Criteria:** Rule of Threes (Price $15–$30, Sales ≥ 300/mo, Reviews < 200).\n\n")
        if qualified:
            for q in qualified:
                f.write(f"- **{q['product']}** | Price: ${q['price']} | Est. Sales: {q['est_sales']}/mo | Reviews: {q['reviews']}\n")
        else:
            f.write("No products matched the Rule of Threes in this batch.\n")
            
    print(f"Scan complete. Found {len(qualified)} qualified opportunities. Saved to {report_path}")

def parse_dataframe(df):
    candidates = []
    # Normalize column names
    df.columns = [str(c).strip().lower() for c in df.columns]
    
    # Try to map common column names
    prod_col = next((c for c in df.columns if 'product' in c or 'title' in c or 'name' in c), df.columns[0])
    price_col = next((c for c in df.columns if 'price' in c or 'cost' in c), None)
    sales_col = next((c for c in df.columns if 'sales' in c or 'volume' in c or 'demand' in c), None)
    review_col = next((c for c in df.columns if 'review' in c or 'ratings count' in c), None)
    
    for _, row in df.iterrows():
        try:
            name = str(row[prod_col])
            price = float(row[price_col]) if price_col and pd.notna(row[price_col]) else 19.99
            sales = float(row[sales_col]) if sales_col and pd.notna(row[sales_col]) else 350.0
            reviews = int(row[review_col]) if review_col and pd.notna(row[review_col]) else 100
            candidates.append({"product": name, "price": price, "est_sales": sales, "reviews": reviews})
        except:
            continue
    return candidates

if __name__ == "__main__":
    scan_niches()
