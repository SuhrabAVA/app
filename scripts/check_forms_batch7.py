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


out_path = os.path.join(ROOT, "scripts", "forms_batch7.txt")
with io.open(out_path, "w", encoding="utf-8") as out:
    forms = get("forms", {"select": "id,number,series", "number": "in.(372,1742,1912,1237)"})
    for f in forms:
        out.write("%s\n" % f)

    out.write("\n--- orders by Бараева (non-GP sample) ---\n")
    rows = get("orders", {"select": "customer,manager", "manager": "ilike.*Бараева*", "limit": "500"})
    seen = set()
    for r in rows:
        c = r["customer"]
        if c not in seen:
            seen.add(c)
            out.write(c + "\n")
print("done")
