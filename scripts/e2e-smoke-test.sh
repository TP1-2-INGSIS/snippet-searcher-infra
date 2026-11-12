#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-https://grupo-6-ingsis.duckdns.org}"
BASE_URL="${BASE_URL%/}"
RUN_ID="$(date +%s)-$$"
USER_A="${2:-e2e-owner-${RUN_ID}}"
USER_B="${3:-e2e-reader-${RUN_ID}}"
SNIPPET_ID=""

cleanup() {
  if [[ -n "${SNIPPET_ID}" ]]; then
    curl -sS -o /dev/null -X DELETE \
      -H "X-User-Id: ${USER_A}" \
      "${BASE_URL}/api/snippets/${SNIPPET_ID}" || true
  fi
}
trap cleanup EXIT

py_assert() {
  local json_input="$1"
  local script="$2"
  JSON_INPUT="${json_input}" python3 -c "
import json, os, sys
data = json.loads(os.environ['JSON_INPUT'])
${script}
"
}

http_status() {
  local method="$1"
  local user="$2"
  local url="$3"
  local body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -sS -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "Content-Type: application/json" \
      -H "X-User-Id: ${user}" \
      -d "${body}" \
      "${url}"
  else
    curl -sS -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "X-User-Id: ${user}" \
      "${url}"
  fi
}

echo "Running full multi-service E2E suite against ${BASE_URL}"
echo "Owner=${USER_A} | Reader=${USER_B}"

echo "==> [1/14] UI & reverse proxy (GET /)"
UI_BODY_FILE="$(mktemp)"
UI_STATUS=$(curl -sS -o "${UI_BODY_FILE}" -w "%{http_code}" "${BASE_URL}/")
if [[ "${UI_STATUS}" != "200" ]] || ! grep -qi "<html" "${UI_BODY_FILE}"; then
  rm -f "${UI_BODY_FILE}"
  echo "FAIL: UI returned HTTP ${UI_STATUS} or invalid HTML" >&2
  exit 1
fi
rm -f "${UI_BODY_FILE}"
echo "OK (HTTP 200 HTML)"

echo "==> [2/14] Language service via Snippets (GET /api/languages)"
LANGS=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/languages")
py_assert "${LANGS}" "
assert isinstance(data, list) and len(data) > 0, 'Expected non-empty languages list'
ps = next((l for l in data if l.get('id') == 'printscript'), None)
assert ps is not None, f'printscript missing in {data}'
assert isinstance(ps.get('versions'), list) and len(ps['versions']) > 0, f'Invalid versions in {ps}'
"
echo "OK (printscript schema verified)"

echo "==> [3/14] Validation error handling (POST /api/snippets blank name -> 400)"
BAD_STATUS=$(http_status POST "${USER_A}" "${BASE_URL}/api/snippets" \
  '{"name":"","language":"printscript","version":"1.1","content":"let x: number = 1;"}')
if [[ "${BAD_STATUS}" != "400" ]]; then
  echo "FAIL: Expected HTTP 400 for invalid snippet, got ${BAD_STATUS}" >&2
  exit 1
fi
echo "OK (HTTP 400)"

echo "==> [4/14] Create snippet + UI Zod Detail schema (POST /api/snippets)"
CREATE_PAYLOAD='{"name":"e2e-smoke","description":"smoke test","language":"printscript","version":"1.1","content":"let x: number = 1;\nprintln(x);"}'
CREATED=$(curl -fsS -X POST \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_A}" \
  -d "${CREATE_PAYLOAD}" \
  "${BASE_URL}/api/snippets")
SNIPPET_ID=$(py_assert "${CREATED}" "
for field in ('id', 'name', 'language', 'version', 'content', 'ownerId', 'role', 'lintStatus', 'createdAt', 'updatedAt'):
    assert isinstance(data.get(field), str) and len(data[field]) > 0, f'Missing/invalid {field}: {data}'
assert data['ownerId'] == '${USER_A}', f'Unexpected ownerId: {data}'
assert data['role'] == 'OWNER', f'Unexpected role: {data}'
assert isinstance(data.get('lintViolations'), list), f'lintViolations not list: {data}'
print(data['id'])
")
echo "OK (id=${SNIPPET_ID})"

echo "==> [5/14] List & detail (GET /api/snippets?relation=OWNED & GET /api/snippets/{id})"
LIST_OWNED=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets?relation=OWNED")
py_assert "${LIST_OWNED}" "
for field in ('items', 'page', 'size', 'total'):
    assert field in data, f'Missing {field} in page: {data}'
item = next((s for s in data['items'] if s.get('id') == '${SNIPPET_ID}'), None)
assert item is not None, 'Created snippet missing in OWNED list'
assert isinstance(item.get('updatedAt'), str) and len(item['updatedAt']) > 0, f'Missing updatedAt in summary: {item}'
"
DETAIL=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
py_assert "${DETAIL}" "
assert isinstance(data.get('createdAt'), str) and isinstance(data.get('updatedAt'), str)
assert data['id'] == '${SNIPPET_ID}'
"
echo "OK"

echo "==> [6/14] Update snippet (PUT /api/snippets/{id})"
UPDATE_PAYLOAD='{"name":"e2e-smoke-updated","description":"smoke test updated","language":"printscript","version":"1.1","content":"let x: number = 42;\nprintln(x);"}'
UPDATED=$(curl -fsS -X PUT \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_A}" \
  -d "${UPDATE_PAYLOAD}" \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}")
py_assert "${UPDATED}" "
assert data.get('name') == 'e2e-smoke-updated'
assert isinstance(data.get('createdAt'), str) and len(data['createdAt']) > 0
assert isinstance(data.get('updatedAt'), str) and len(data['updatedAt']) > 0
"
echo "OK"

echo "==> [7/14] Download raw & formatted via Language (GET /api/snippets/{id}/download)"
DL_HEADERS="$(mktemp)"
DL_BODY=$(curl -fsS -D "${DL_HEADERS}" -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/download")
if ! grep -qi 'content-disposition:.*attachment.*\.ps' "${DL_HEADERS}" || [[ "${DL_BODY}" != *"println(x);"* ]]; then
  rm -f "${DL_HEADERS}"
  echo "FAIL: Download unexpected headers/body: ${DL_BODY}" >&2
  exit 1
fi
rm -f "${DL_HEADERS}"
DL_FMT=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/download?formatted=true")
if [[ "${DL_FMT}" != *"println(x);"* ]]; then
  echo "FAIL: Formatted download unexpected body: ${DL_FMT}" >&2
  exit 1
fi
echo "OK"

echo "==> [8/14] Permissions user directory & unauthorized 404 checks (D04)"
USERS=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/users?search=&limit=5")
py_assert "${USERS}" "assert isinstance(data, list), f'Expected list from /api/users, got {data}'"

UNAUTH_READ=$(http_status GET "${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
UNAUTH_SHARE=$(http_status POST "${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/share" "{\"userId\":\"${USER_B}\"}")
if [[ "${UNAUTH_READ}" != "404" || "${UNAUTH_SHARE}" != "404" ]]; then
  echo "FAIL: Expected 404 for unshared user B (read=${UNAUTH_READ}, share=${UNAUTH_SHARE})" >&2
  exit 1
fi
echo "OK (user list valid, unshared read/share hidden with 404)"

echo "==> [9/14] Permissions sharing flow (POST /share 204, duplicate 409, reader 200, reader write 403)"
SHARE_STATUS=$(http_status POST "${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/share" "{\"userId\":\"${USER_B}\"}")
if [[ "${SHARE_STATUS}" != "204" ]]; then
  echo "FAIL: Expected HTTP 204 sharing snippet, got ${SHARE_STATUS}" >&2
  exit 1
fi

DUP_SHARE_STATUS=$(http_status POST "${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/share" "{\"userId\":\"${USER_B}\"}")
if [[ "${DUP_SHARE_STATUS}" != "409" ]]; then
  echo "FAIL: Expected HTTP 409 on duplicate share, got ${DUP_SHARE_STATUS}" >&2
  exit 1
fi

OWNER_DETAIL=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
py_assert "${OWNER_DETAIL}" "assert '${USER_B}' in (data.get('sharedWith') or []), f'sharedWith missing reader: {data}'"

READER_DETAIL=$(curl -fsS -H "X-User-Id: ${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
py_assert "${READER_DETAIL}" "assert data.get('role') == 'READ', f'Expected role=READ for shared user, got {data}'"

LIST_SHARED=$(curl -fsS -H "X-User-Id: ${USER_B}" "${BASE_URL}/api/snippets?relation=SHARED")
py_assert "${LIST_SHARED}" "
item = next((s for s in data['items'] if s.get('id') == '${SNIPPET_ID}'), None)
assert item is not None, f'Shared snippet missing in SHARED list for ${USER_B}: {data}'
"

READER_PUT=$(http_status PUT "${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}" '{"name":"hacked"}')
READER_DEL=$(http_status DELETE "${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
if [[ "${READER_PUT}" != "403" || "${READER_DEL}" != "403" ]]; then
  echo "FAIL: Expected 403 for READ user write/delete (put=${READER_PUT}, del=${READER_DEL})" >&2
  exit 1
fi
echo "OK"

echo "==> [10/14] Test cases CRUD (POST/GET/PUT /api/snippets/{id}/tests)"
CREATED_TEST=$(curl -fsS -X POST \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_A}" \
  -d '{"name":"prints-42","inputs":[],"expectedOutputs":["42"]}' \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests")
TEST_ID=$(py_assert "${CREATED_TEST}" "
for f in ('id', 'name', 'inputs', 'expectedOutputs', 'lastStatus'):
    assert f in data, f'Missing {f} in TestView: {data}'
print(data['id'])
")

TESTS_LIST=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests")
py_assert "${TESTS_LIST}" "assert any(t.get('id') == '${TEST_ID}' for t in data)"

UPDATED_TEST=$(curl -fsS -X PUT \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_A}" \
  -d '{"name":"prints-42-v2","inputs":[],"expectedOutputs":["42"]}' \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests/${TEST_ID}")
py_assert "${UPDATED_TEST}" "assert data.get('name') == 'prints-42-v2'"
echo "OK (testId=${TEST_ID})"

echo "==> [11/14] Run test via Language (POST /api/snippets/{id}/tests/{testId}/run)"
RUN_RESULT=$(curl -fsS -X POST \
  -H "X-User-Id: ${USER_A}" \
  "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests/${TEST_ID}/run")
RUN_STATUS=$(py_assert "${RUN_RESULT}" "
assert data.get('testId') == '${TEST_ID}', f'testId mismatch: {data}'
assert data.get('status') in ('PASSED', 'FAILED'), f'Unexpected status: {data}'
assert isinstance(data.get('expectedOutputs'), list) and isinstance(data.get('actualOutputs'), list)
print(data['status'])
")
echo "OK (status=${RUN_STATUS})"

echo "==> [12/14] Delete test case (DELETE /api/snippets/{id}/tests/{testId})"
DEL_TEST_STATUS=$(http_status DELETE "${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests/${TEST_ID}")
if [[ "${DEL_TEST_STATUS}" != "204" ]]; then
  echo "FAIL: Expected HTTP 204 deleting test, got ${DEL_TEST_STATUS}" >&2
  exit 1
fi
echo "OK (HTTP 204)"

echo "==> [13/14] Rules get & apply (GET/PUT /api/rules/printscript/{lint,format})"
for KIND in lint format; do
  RULE_GET=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/rules/printscript/${KIND}")
  py_assert "${RULE_GET}" "
assert data.get('language') == 'printscript'
assert data.get('kind') == '${KIND}'.upper()
assert isinstance(data.get('config'), dict)
"
  RULE_PUT=$(curl -fsS -X PUT \
    -H "Content-Type: application/json" \
    -H "X-User-Id: ${USER_A}" \
    -d '{"config":{}}' \
    "${BASE_URL}/api/rules/printscript/${KIND}")
  py_assert "${RULE_PUT}" "
assert data.get('processed', 0) >= 1, f'Expected processed >= 1: {data}'
assert data.get('failed') == 0, f'Expected failed == 0: {data}'
"
done
echo "OK (lint & format applied cleanly)"

echo "==> [14/14] Delete snippet & verify cleanup (DELETE -> 204, subsequent GET -> 403/404)"
DEL_STATUS=$(http_status DELETE "${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
if [[ "${DEL_STATUS}" != "204" ]]; then
  echo "FAIL: Expected HTTP 204 on DELETE snippet, got ${DEL_STATUS}" >&2
  exit 1
fi
AFTER_DEL_OWNER=$(http_status GET "${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
if [[ "${AFTER_DEL_OWNER}" != "403" && "${AFTER_DEL_OWNER}" != "404" ]]; then
  echo "FAIL: Expected HTTP 403/404 after delete, got ${AFTER_DEL_OWNER}" >&2
  exit 1
fi
SNIPPET_ID=""
echo "OK (HTTP 204, post-delete GET returned ${AFTER_DEL_OWNER})"

echo "ALL 14 MULTI-SERVICE E2E CHECKS PASSED against ${BASE_URL}"
