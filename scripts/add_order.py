"""Быстрый ввод заказов из бумажного бланка прямо в Supabase.

Повторяет то, что делает форма заказа (edit_order_screen -> provider.createOrder
-> _persistPaints): INSERT в orders, затем RPC save_order_paints и
sync_order_paint_reservations.

Правило проекта: краски и бумага берутся только тестовые (в названии «тест»),
остальные данные — реальные с бланка. Скрипт это проверяет и падает, если
подставлена не тестовая позиция (снять проверку: --allow-non-test).

Запуск:
    python scripts/add_order.py orders.json           # создать
    python scripts/add_order.py orders.json --dry-run # только показать payload

orders.json — объект или список объектов вида:
{
  "manager": "Бараева Захидам менеджер",
  "customer": "Дареджани",
  "order_date": "2026-08-13",
  "due_date": null,
  "product_type": "П-образный пакет",
  "quantity": 10000,
  "length_mm": 30, "width_mm": 30, "depth_mm": 25,
  "paper": {"name": "Тестовая бумага", "format": "333", "grammage": "444"},
  "width_b": 44.5, "bl_quantity": "2", "length_l": 6150,
  "handle": "Крученые • коричневые",
  "cardboard": "есть",
  "makeready": 500, "val": 60,
  "form": {"series": "дареджани", "number": 458},
  "paints": [{"name": "Тест Чёрный Чёрный", "grams": 20}],
  "paint_info": "",
  "packaging": "",
  "trimming": false,
  "comments": "печатается боком"
}
"""

import argparse
import io
import json
import os
import re
import sys
import uuid
from urllib import error, parse, request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_MARKER = "тест"  # «тест»


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
    url = env.get("SUPABASE_URL")
    key = env.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise SystemExit("В .env.scripts нет SUPABASE_URL или SUPABASE_SERVICE_ROLE_KEY")
    return url.rstrip("/"), key


class Rest:
    def __init__(self, url, key):
        self.url = url
        self.key = key

    def _call(self, method, path, query=None, body=None, prefer=None):
        target = self.url + path
        if query:
            target += "?" + parse.urlencode(query, quote_via=parse.quote)
        data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        req = request.Request(target, data=data, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", "Bearer " + self.key)
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept-Profile", "public")
        if prefer:
            req.add_header("Prefer", prefer)
        try:
            with request.urlopen(req) as resp:
                raw = resp.read().decode("utf-8")
        except error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise SystemExit("%s %s -> %s %s" % (method, path, exc.code, detail))
        return json.loads(raw) if raw.strip() else None

    def get(self, table, query):
        return self._call("GET", "/rest/v1/" + table, query=query)

    def insert(self, table, row):
        return self._call(
            "POST", "/rest/v1/" + table, body=row, prefer="return=representation"
        )

    def rpc(self, name, params):
        return self._call("POST", "/rest/v1/rpc/" + name, body=params)


def is_test(name):
    return TEST_MARKER in (name or "").lower()


def fetch_all(rest, table, columns):
    return rest.get(table, {"select": columns, "limit": "5000"})


def resolve_category(rest, title):
    rows = fetch_all(rest, "warehouse_categories", "id,title")
    for row in rows:
        if (row["title"] or "").strip().lower() == (title or "").strip().lower():
            return row
    raise SystemExit(
        "Тип продукта %r не найден. Доступные: %s"
        % (title, ", ".join(sorted(r["title"] for r in rows)))
    )


def resolve_paper(rest, spec, allow_non_test):
    rows = fetch_all(rest, "papers", "id,description,format,grammage,unit,quantity")
    name = (spec.get("name") or "").strip().lower()
    fmt = str(spec.get("format") or "").strip()
    gram = str(spec.get("grammage") or "").strip()
    matches = [
        r
        for r in rows
        if (r["description"] or "").strip().lower() == name
        and (not fmt or str(r["format"] or "").strip() == fmt)
        and (not gram or str(r["grammage"] or "").strip() == gram)
    ]
    if not matches:
        raise SystemExit("Бумага %r (формат %s, граммаж %s) не найдена" % (spec.get("name"), fmt, gram))
    paper = matches[0]
    if not allow_non_test and not is_test(paper["description"]):
        raise SystemExit(
            "Бумага %r не тестовая. Правило: только тестовая бумага (--allow-non-test чтобы обойти)"
            % paper["description"]
        )
    return paper


def resolve_paints(rest, specs, allow_non_test):
    if not specs:
        return []
    rows = fetch_all(rest, "paints", "id,description,unit,quantity")
    resolved = []
    for spec in specs:
        wanted = (spec.get("name") or "").strip().lower()
        found = None
        for row in rows:
            if (row["description"] or "").strip().lower() == wanted:
                found = row
                break
        if found is None:
            raise SystemExit("Краска %r не найдена в справочнике" % spec.get("name"))
        if not allow_non_test and not is_test(found["description"]):
            raise SystemExit(
                "Краска %r не тестовая. Правило: только тестовые краски (--allow-non-test чтобы обойти)"
                % found["description"]
            )
        resolved.append({"row": found, "grams": spec.get("grams")})
    return resolved


def format_grams(grams):
    if grams is None:
        return None
    text = ("%.2f" % grams) if grams % 1 else ("%d" % int(grams))
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text + " г"


def build_parameters(paints, paint_info):
    """Дублирует строки красок в product.parameters — как _persistPaints."""
    chunks = []
    info = (paint_info or "").strip()
    for item in paints:
        grams = item.get("grams")
        if not grams:
            continue
        line = "Краска: %s %s" % (
            item["row"]["description"],
            format_grams(grams),
        )
        if info:
            line += " (%s)" % info
        chunks.append(line)
    if info:
        chunks.append("Информация для красок: " + info)
    return "; ".join(chunks)


def to_iso(value):
    if not value:
        return None
    text = str(value).strip()
    if re.match(r"^\d{2}\.\d{2}\.\d{4}$", text):
        day, month, year = text.split(".")
        text = "%s-%s-%s" % (year, month, day)
    if re.match(r"^\d{4}-\d{2}-\d{2}$", text):
        text += "T00:00:00"
    return text


def build_payload(rest, sheet, allow_non_test):
    category = resolve_category(rest, sheet.get("product_type"))
    paper = resolve_paper(rest, sheet.get("paper") or {}, allow_non_test)
    paints = resolve_paints(rest, sheet.get("paints") or [], allow_non_test)

    length_l = sheet.get("length_l")
    material = {
        "id": paper["id"],
        "name": paper["description"],
        "unit": paper.get("unit") or "м",
        "format": paper.get("format"),
        "grammage": paper.get("grammage"),
        "weight": 0.0,
        "quantity": float(length_l) if length_l else 0.0,
    }

    params = []
    if sheet.get("trimming"):
        params.append("Подрезка")
    packaging = (sheet.get("packaging") or "").strip()
    if packaging:
        params.append("Упаковка: " + packaging)

    product = {
        "id": str(uuid.uuid4()),
        "type": category["title"],
        "quantity": int(sheet.get("quantity") or 0),
        "width": float(sheet.get("length_mm") or 0),   # поле «Длина» в форме
        "height": float(sheet.get("width_mm") or 0),   # поле «Ширина» в форме
        "depth": float(sheet.get("depth_mm") or 0),
        "parameters": build_parameters(paints, sheet.get("paint_info")),
    }
    if sheet.get("width_b") is not None:
        product["widthB"] = float(sheet["width_b"])
    if sheet.get("bl_quantity"):
        product["blQuantity"] = str(sheet["bl_quantity"])
    if length_l is not None:
        product["length"] = float(length_l)

    form = sheet.get("form") or {}
    order = {
        "manager": sheet.get("manager") or "",
        "customer": sheet.get("customer") or "",
        "order_date": to_iso(sheet.get("order_date")),
        "due_date": to_iso(sheet.get("due_date")),
        "product": product,
        "additional_params": params,
        "handle": sheet.get("handle") or "-",
        "cardboard": sheet.get("cardboard") or "нет",
        "material": material,
        "material_list": [material],
        "makeready": float(sheet.get("makeready") or 0),
        "val": float(sheet.get("val") or 0),
        "has_form": bool(form),
        "is_old_form": bool(form),
        "new_form_no": form.get("number"),
        "form_series": form.get("series"),
        "contract_signed": False,
        "payment_done": False,
        "comments": sheet.get("comments") or "",
        "status": "draft",
        "queue_build_status": "not_built",
        "has_material_shortage": False,
        "material_shortage_message": "",
        "assignment_created": False,
        "restart_generation": 0,
        "product_type_id": category["id"],
    }
    order = {k: v for k, v in order.items() if v is not None}
    return order, paints


def create_order(rest, sheet, allow_non_test, dry_run):
    order, paints = build_payload(rest, sheet, allow_non_test)
    if dry_run:
        print(json.dumps(order, ensure_ascii=False, indent=2))
        return None
    inserted = rest.insert("orders", order)
    order_id = inserted[0]["id"]

    rows = [
        {
            "order_id": order_id,
            "name": item["row"]["description"],
            "info": (sheet.get("paint_info") or "").strip() or None,
            "qty_kg": (item["grams"] / 1000.0) if item.get("grams") else None,
        }
        for item in paints
    ]
    if rows:
        rest.rpc("save_order_paints", {"p_order_id": order_id, "p_paints": rows})
        reservations = [
            {
                "paint_id": item["row"]["id"],
                "paint_name": item["row"]["description"],
                "reserved_qty": float(item["grams"]),
            }
            for item in paints
            if item.get("grams")
        ]
        if reservations:
            try:
                rest.rpc(
                    "sync_order_paint_reservations",
                    {
                        "p_order_id": order_id,
                        "p_reservations": reservations,
                        "p_actor": "add_order.py",
                    },
                )
            except SystemExit as exc:
                print("  резерв краски не создан: %s" % exc)
    return order_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", help="JSON-файл с заказом или списком заказов")
    parser.add_argument("--dry-run", action="store_true", help="только показать payload")
    parser.add_argument(
        "--allow-non-test",
        action="store_true",
        help="разрешить нетестовые краски/бумагу",
    )
    args = parser.parse_args()

    with io.open(args.payload, encoding="utf-8") as fh:
        data = json.load(fh)
    sheets = data if isinstance(data, list) else [data]

    url, key = load_env()
    rest = Rest(url, key)
    for sheet in sheets:
        order_id = create_order(rest, sheet, args.allow_non_test, args.dry_run)
        if order_id:
            print("создан заказ %s — %s / %s" % (order_id, sheet.get("customer"), sheet.get("product_type")))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
