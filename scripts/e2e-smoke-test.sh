#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-https://grupo-6-ingsis.duckdns.org}"
BASE_URL="${BASE_URL%/}"
USER_ID="${2:-e2e-smoke-user}"
SNIPPET_ID=""

cleanup() {
  if [[ -n "${SNIPPET_ID}" ]]; then
    curl -sS -o /dev/null -X DELETE \
      -H "X-User-Id: ${USER_ID}" \
      "${BASE_URL}/api/snippets/${SNIPPET_ID}" || true
  fi
}
trap cleanup EXIT

json_get() {
  local json="$1"
  local expr="$2"
  JSON_INPUT="${json}" python3 -c "
import json, os, sys
data = json.loads(os.environ['JSON_INPUT'])
val = (${expr})
if val is None:
    sys.exit(2)
print(val)
"
}

echo "==> [1/9] Checking UI at ${BASE_URL}/"
UI_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/")
if [[ "${UI_STATUS}" != "200" ]]; then
  echo "FAIL: UI returned HTTP ${UI_STATUS}" >&2
  exit 1
fi
echo "OK (HTTP 200)"

echo "==> [2/9] Checking GET /api/languages"
LANGS=$(curl -fsS -H "X-User-Id: ${USER_ID}" "${BASE_URL}/api/languages")
json_get "${LANGS}" "next(l['id'] for l in data if l['id'] == 'printscript')" >/dev/null
echo "OK (printscript available)"

echo "==> [3/9] Checking POST /api/snippets (schema + non-null timestamps)"
CREATE_PAYLOAD='{"name":"e2e-smoke","description":"smoke test","language":"printscript","version":"1.1","content":"let x: number = 1;\nprintln(x);"}'
CREATED=$(curl -fsS -X POST \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_ID}" \
  -d "${CREATE_PAYLOAD}" \
  "${BASE_URL}/api/snippets")
SNIPPET_ID=$(json_get "${CREATED}" "data['id']")
CREATED_AT=$(json_get "${CREATED}" "data['createdAt']")
UPDATED_AT=$(json_get "${CREATED}" "data['updatedAt']")
if [[ -z "${SNIPPET_ID}" || -z "${CREATED_AT}" || -z "${UPDATED_AT}" ]]; then
  echo "FAIL: Missing id/createdAt/updatedAt in POST /api/snippets response: ${CREATED}" >&2
  exit 1
fi
echo "OK (id=${SNIPPET_ID}, createdAt=${CREATED_AT})"

echo "==> [4/9] Checking GET /api/snippets"
LIST=$(curl -fsS -H "X-User-Id: ${USER_ID}" "${BASE_URL}/api/snippets")
json_get "${LIST}" "next(s['id'] for s in data['items'] if s['id'] == '${SNIPPET_ID}')" >/dev/null
echo "OK (created snippet present in list)"

echo "==> [5/9] Checking GET /api/snippets/${SNIPPET_ID}"
DETAIL=$(curl -fsS -H "X-User-Id: ${USER_ID}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
json_get "${DETAIL}" "data['createdAt']" >/dev/null
json_get "${DETAIL}" "data['updatedAt']" >/dev/null
echo "OK"

echo "==> [6/9] Checking PUT /api/snippets/${SNIPPET_ID}"
UPDATE_PAYLOAD='{"name":"e2e-smoke-updated","description":"smoke test updated","language":"printscript","version":"1.1","content":"let x: number = 42;\nprintln(x);"}'
UPDATED=$(curl -fsS -X PUT \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_ID}" \
  -d "${UPDATE_PAYLOAD}" \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}")
UPDATED_AT_2=$(json_get "${UPDATED}" "data['updatedAt']")
json_get "${UPDATED}" "data['createdAt']" >/dev/null
echo "OK (updatedAt=${UPDATED_AT_2})"

echo "==> [7/9] Checking POST /api/snippets/${SNIPPET_ID}/tests"
TEST_PAYLOAD='{"name":"prints-42","inputs":[],"expectedOutputs":["42"]}'
CREATED_TEST=$(curl -fsS -X POST \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_ID}" \
  -d "${TEST_PAYLOAD}" \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests")
TEST_ID=$(json_get "${CREATED_TEST}" "data['id']")
echo "OK (testId=${TEST_ID})"

echo "==> [8/9] Checking POST /api/snippets/${SNIPPET_ID}/tests/${TEST_ID}/run"
RUN_RESULT=$(curl -fsS -X POST \
  -H "X-User-Id: ${USER_ID}" \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests/${TEST_ID}/run")
RUN_STATUS=$(json_get "${RUN_RESULT}" "data['status']")
if [[ "${RUN_STATUS}" != "PASSED" && "${RUN_STATUS}" != "FAILED" ]]; then
  echo "FAIL: Unexpected test run status ${RUN_STATUS}: ${RUN_RESULT}" >&2
  exit 1
fi
echo "OK (status=${RUN_STATUS})"

echo "==> [9/9] Checking GET /api/rules/printscript/lint and DELETE /api/snippets/${SNIPPET_ID}"
curl -fsS -H "X-User-Id: ${USER_ID}" "${BASE_URL}/api/rules/printscript/lint" >/dev/null
DEL_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
  -H "X-User-Id: ${USER_ID}" \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}")
if [[ "${DEL_STATUS}" != "204" ]]; then
  echo "FAIL: Expected HTTP 204 on DELETE, got ${DEL_STATUS}" >&2
  exit 1
fi
SNIPPET_ID=""
echo "OK (HTTP 204)"

echo "ALL E2E SMOKE CHECKS PASSED against ${BASE_URL}"
