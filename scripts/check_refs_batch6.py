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


out_path = os.path.join(ROOT, "scripts", "refs_batch6.txt")
with io.open(out_path, "w", encoding="utf-8") as out:
    cats = get("warehouse_categories", {"select": "id,title", "order": "title"})
    out.write("=== warehouse_categories ===\n")
    for c in cats:
        out.write("%s\n" % c["title"])

    out.write("\n=== forms (1913,1670,452,933) ===\n")
    forms = get("forms", {"select": "id,number,series", "number": "in.(1913,1670,452,933)"})
    for f in forms:
        out.write("%s\n" % f)

    out.write("\n=== paints matching ===\n")
    paints = get("paints", {"select": "description", "description": "ilike.*тест*"})
    for p in paints:
        out.write("%s\n" % p["description"])

print("done")
