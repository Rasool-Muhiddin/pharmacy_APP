#!/usr/bin/env bash
# يقيس زمن endpoints الإنتاج كما تطلبها كل شاشة (أونلاين)، مع فصل زمن الشبكة
# عن زمن الخادم. التوكن يُقرأ من TERA_TOKEN أو من الملف ~/.tera_token (لا
# تكتبه في سطر الأوامر).
#
#   bash tools/measure_api_latency.sh            # 3 مرات لكل طلب
#   RUNS=5 BASE=https://... bash tools/measure_api_latency.sh
#
# الأعمدة (ثوانٍ): dns, tcp, tls = إعداد اتصال جديد؛ ttfb−tls ≈ ذهاب/إياب +
# زمن الخادم؛ srv = ترويسة Server-Timing (فقط إن كان REQUEST_TIMING=True على الخادم).
set -u
BASE="${BASE:-https://pharmacy-api.tera-software1.com}"
RUNS="${RUNS:-3}"
TOKEN="${TERA_TOKEN:-$(cat ~/.tera_token 2>/dev/null)}"
[ -z "$TOKEN" ] && { echo "Set TERA_TOKEN or put the token in ~/.tera_token"; exit 1; }
START=$(date -d '-30 days' +%F 2>/dev/null || date -v-30d +%F)
END=$(date +%F)
TMP=$(mktemp)

timed() { # $1=path  → سطر واحد بالأزمنة (اتصال جديد في كل مرة، مثل التطبيق حالياً)
  curl -s -o "$TMP.body" -D "$TMP.hdr" -H "Authorization: Token $TOKEN" -H "Accept: application/json" \
    --compressed -w "%{http_code} dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}" \
    "$BASE$1"
  local srv; srv=$(grep -i '^server-timing' "$TMP.hdr" | sed 's/^[^:]*: *//' | tr -d '\r')
  echo " ${srv:+srv=[$srv]}"
}

pages() { # عدد الصفحات لقائمة مُرقَّمة (PAGE_SIZE=100)
  local count
  count=$(curl -s -H "Authorization: Token $TOKEN" "$BASE$1" | grep -o '"count": *[0-9]*' | grep -o '[0-9]*$')
  echo $(( (${count:-0} + 99) / 100 ))" (count=${count:-?})"
}

section() { echo; echo "=== $1"; }
run() { for i in $(seq "$RUNS"); do printf '%-55s ' "$1"; timed "$1"; done; }

section "Pages per full-list sync"
echo "medicines pages: $(pages /api/medicines/)"
echo "invoices pages:  $(pages /api/invoices/) — no longer fetched in full by the app"

section "Inventory (warehouses → all medicine pages, sequential; no /health/)"
run /api/warehouses/; run /api/medicines/; run "/api/medicines/?page=2"

section "POS (= inventory chain ‖ last 20 invoices); search itself is local, no request"
run "/api/invoices/?page=1&page_size=20"

section "Sales history (one page of 50, filters on the server)"
run "/api/invoices/?page=1&page_size=50"; run "/api/invoices/?page=1&page_size=50&start=$START&end=$END"

section "Dashboard (inventory chain ‖ today stats)"
run /api/invoices/stats/

section "Suppliers (one shared suppliers/summary)"
run /api/suppliers/summary/

section "Reports overview (kpis, trend, categories, hours in parallel, no health check)"
for s in kpis trend categories hours; do run "/api/reports/$s/?start=$START&end=$END"; done

section "Same 5 calls over ONE reused connection (what the shared keep-alive client costs)"
curl -s -H "Authorization: Token $TOKEN" --compressed \
  -o /dev/null -o /dev/null -o /dev/null -o /dev/null -o /dev/null \
  -w "%{url_effective} %{http_code} new_conn=%{num_connects} ttfb=%{time_starttransfer} total=%{time_total}\n" \
  "$BASE/api/health/" "$BASE/api/warehouses/" "$BASE/api/medicines/" "$BASE/api/invoices/" "$BASE/api/suppliers/summary/"

rm -f "$TMP" "$TMP.body" "$TMP.hdr"
