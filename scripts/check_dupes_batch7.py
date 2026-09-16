import io
import json
import os
from urllib import parse, request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env():
    env = {}
    # Ключ service_role живёт в .env.scripts: .env упакован в сборку приложения.
    path = next((p for p in (os.path.join(ROOT, ".env.scripts"), os.path.join(ROOT, ".env")) if os.path.exists(p)), os.path.join(ROOT, ".env"))
    with io.open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env["SUPABASE_URL"].rstrip("/"), env["SUPABASE_SERVICE_ROLE_KEY"]


url, key = load_env()


def get(table, query):
    target = url + "/rest/v1/" + table + "?" + parse.urlencode(query, quote_via=parse.quote)
    req = request.Request(target, method="GET")
    req.add_header("apikey", key)
    req.add_header("Authorization", "Bearer " + key)
    with request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))


out_path = os.path.join(ROOT, "scripts", "dupes_batch7.txt")
with io.open(out_path, "w", encoding="utf-8") as out:
    for term in ["coco", "food house", "chicken", "чикен", "лосось", "данилов"]:
        rows = get("orders", {"select": "id,customer,manager,order_date,product", "customer": "ilike.*%s*" % term})
        out.write("=== %s (%d) ===\n" % (term, len(rows)))
        for r in rows:
            p = r.get("product") or {}
            out.write("%s | %s | %s | qty=%s size=%sx%sx%s\n" % (
                r.get("order_date"), r.get("customer"), r.get("manager"),
                p.get("quantity"), p.get("width"), p.get("height"), p.get("depth")))
print("done")
