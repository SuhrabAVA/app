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


out_path = os.path.join(ROOT, "scripts", "myor_history.txt")
with io.open(out_path, "w", encoding="utf-8") as out:
    orders = get("orders", {"select": "id,customer,order_date,comments", "customer": "ilike.*myor*"})
    out.write("orders customer ilike myor: %d\n" % len(orders))
    for o in orders:
        out.write("%s | %s | %s\n" % (o["order_date"], o["customer"], (o.get("comments") or "")[:200]))
        paints = get("order_paints", {"select": "name,info,qty_kg", "order_id": "eq.%s" % o["id"]})
        for p in paints:
            out.write("   paint: %s | %s | %s\n" % (p["name"], p.get("info"), p.get("qty_kg")))
print("done")
