#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-https://grupo-6-ingsis.duckdns.org}"
BASE_URL="${BASE_URL%/}"
RUN_ID="$(date +%s)-$$"
USER_A="${2:-e2e-owner-${RUN_ID}}"
USER_B="${3:-e2e-reader-${RUN_ID}}"
SNIPPET_ID=""
RUN_SNIPPET_ID_TO_DELETE=""

cleanup() {
  if [[ -n "${RUN_SNIPPET_ID_TO_DELETE}" ]]; then
    curl -sS -o /dev/null -X DELETE -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${RUN_SNIPPET_ID_TO_DELETE}" || true
  fi
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

echo "==> [1/22] UI & reverse proxy (GET /)"
UI_BODY_FILE="$(mktemp)"
UI_STATUS=$(curl -sS -o "${UI_BODY_FILE}" -w "%{http_code}" "${BASE_URL}/")
if [[ "${UI_STATUS}" != "200" ]] || ! grep -qi "<html" "${UI_BODY_FILE}"; then
  rm -f "${UI_BODY_FILE}"
  echo "FAIL: UI returned HTTP ${UI_STATUS} or invalid HTML" >&2
  exit 1
fi
rm -f "${UI_BODY_FILE}"
echo "OK (HTTP 200 HTML)"

echo "==> [2/22] Language service via Snippets (GET /api/languages)"
LANGS=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/languages")
py_assert "${LANGS}" "
assert isinstance(data, list) and len(data) > 0, 'Expected non-empty languages list'
ps = next((l for l in data if l.get('id') == 'printscript'), None)
assert ps is not None, f'printscript missing in {data}'
assert isinstance(ps.get('versions'), list) and len(ps['versions']) > 0, f'Invalid versions in {ps}'
"
echo "OK (printscript schema verified)"

echo "==> [3/22] Validation error handling (POST /api/snippets blank name -> 400)"
BAD_STATUS=$(http_status POST "${USER_A}" "${BASE_URL}/api/snippets" \
  '{"name":"","language":"printscript","version":"1.1","content":"let x: number = 1;"}')
if [[ "${BAD_STATUS}" != "400" ]]; then
  echo "FAIL: Expected HTTP 400 for invalid snippet, got ${BAD_STATUS}" >&2
  exit 1
fi
echo "OK (HTTP 400)"

echo "==> [4/22] Create snippet + UI Zod Detail schema (POST /api/snippets)"
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

echo "==> [5/22] List & detail (GET /api/snippets?relation=OWNED & GET /api/snippets/{id})"
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

echo "==> [6/22] Update snippet (PUT /api/snippets/{id})"
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

echo "==> [7/22] Download raw & formatted via Language (GET /api/snippets/{id}/download)"
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

echo "==> [8/22] Permissions user directory & unauthorized 404 checks (D04)"
USERS=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/users?search=&limit=5")
py_assert "${USERS}" "assert isinstance(data, list), f'Expected list from /api/users, got {data}'"

UNAUTH_READ=$(http_status GET "${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
UNAUTH_SHARE=$(http_status POST "${USER_B}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/share" "{\"userId\":\"${USER_B}\"}")
if [[ "${UNAUTH_READ}" != "404" || "${UNAUTH_SHARE}" != "404" ]]; then
  echo "FAIL: Expected 404 for unshared user B (read=${UNAUTH_READ}, share=${UNAUTH_SHARE})" >&2
  exit 1
fi
echo "OK (user list valid, unshared read/share hidden with 404)"

echo "==> [9/22] Permissions sharing flow (POST /share 204, duplicate 409, reader 200, reader write 403)"
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

echo "==> [10/22] Test cases CRUD (POST/GET/PUT /api/snippets/{id}/tests)"
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

echo "==> [11/22] Run test via Language (POST /api/snippets/{id}/tests/{testId}/run)"
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

echo "==> [12/22] Delete test case (DELETE /api/snippets/{id}/tests/{testId})"
DEL_TEST_STATUS=$(http_status DELETE "${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/tests/${TEST_ID}")
if [[ "${DEL_TEST_STATUS}" != "204" ]]; then
  echo "FAIL: Expected HTTP 204 deleting test, got ${DEL_TEST_STATUS}" >&2
  exit 1
fi
echo "OK (HTTP 204)"

echo "==> [13/22] Rules get & enqueue (GET/PUT /api/rules/printscript/{lint,format})"
for KIND in lint format; do
  RULE_GET=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/rules/printscript/${KIND}")
  py_assert "${RULE_GET}" "
assert data.get('language') == 'printscript'
assert data.get('kind') == '${KIND}'.upper()
assert isinstance(data.get('config'), dict)
"
  # Rules are applied asynchronously (workers via Redis Streams): the PUT answers 202 Accepted
  # with the number of queued tasks and does not wait for any lint/format result.
  RULE_PUT_FILE=$(mktemp)
  RULE_PUT_STATUS=$(curl -sS -o "${RULE_PUT_FILE}" -w "%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    -H "X-User-Id: ${USER_A}" \
    -d '{"config":{}}' \
    "${BASE_URL}/api/rules/printscript/${KIND}")
  if [[ "${RULE_PUT_STATUS}" != "202" ]]; then
    echo "FAIL: Expected HTTP 202 on PUT rules/${KIND}, got ${RULE_PUT_STATUS}" >&2
    cat "${RULE_PUT_FILE}" >&2
    rm -f "${RULE_PUT_FILE}"
    exit 1
  fi
  RULE_PUT=$(cat "${RULE_PUT_FILE}")
  rm -f "${RULE_PUT_FILE}"
  py_assert "${RULE_PUT}" "
assert data.get('kind') == '${KIND}'.upper(), f'Unexpected kind: {data}'
assert data.get('queued', 0) >= 1, f'Expected queued >= 1: {data}'
"
done
echo "OK (lint & format accepted with HTTP 202)"

echo "==> [15/22] On-demand format (POST /api/snippets/format: valid -> 200, invalid -> 422)"
FMT_FILE=$(mktemp)
FMT_STATUS=$(curl -sS -o "${FMT_FILE}" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" -H "X-User-Id: ${USER_A}" \
  -d '{"content":"let   x:number=1;println(x);","language":"printscript","version":"1.1"}' \
  "${BASE_URL}/api/snippets/format")
if [[ "${FMT_STATUS}" != "200" ]]; then
  echo "FAIL: Expected HTTP 200 formatting valid code, got ${FMT_STATUS}: $(cat "${FMT_FILE}")" >&2
  exit 1
fi
py_assert "$(cat "${FMT_FILE}")" "
c = data.get('content')
assert isinstance(c, str) and 'println' in c and 'let' in c, f'Unexpected formatted content: {data}'
"
FMT_BAD_STATUS=$(curl -sS -o "${FMT_FILE}" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" -H "X-User-Id: ${USER_A}" \
  -d '{"content":"let x: number = ;","language":"printscript","version":"1.1"}' \
  "${BASE_URL}/api/snippets/format")
if [[ "${FMT_BAD_STATUS}" != "422" ]]; then
  echo "FAIL: Expected HTTP 422 formatting invalid code, got ${FMT_BAD_STATUS}: $(cat "${FMT_FILE}")" >&2
  exit 1
fi
py_assert "$(cat "${FMT_FILE}")" "
d = data.get('details')
assert isinstance(d, list) and len(d) > 0, f'Expected violations in details: {data}'
"
rm -f "${FMT_FILE}"
echo "PASS (200 with formatted content, 422 with violations)"

echo "==> [16/22] Real validation on create (invalid snippet -> 422 with rule/line/column)"
INV_FILE=$(mktemp)
INV_STATUS=$(curl -sS -o "${INV_FILE}" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" -H "X-User-Id: ${USER_A}" \
  -d '{"name":"e2e-invalid","language":"printscript","version":"1.1","content":"let x: number = ;"}' \
  "${BASE_URL}/api/snippets")
if [[ "${INV_STATUS}" != "422" ]]; then
  echo "FAIL: Expected HTTP 422 creating invalid snippet, got ${INV_STATUS}: $(cat "${INV_FILE}")" >&2
  exit 1
fi
py_assert "$(cat "${INV_FILE}")" "
d = data.get('details')
assert isinstance(d, list) and len(d) > 0, f'Expected details: {data}'
for k in ('rule', 'line', 'column'):
    assert d[0].get(k) is not None, f'Missing/null {k} in violation {d[0]}'
"
rm -f "${INV_FILE}"
echo "PASS (422 with rule/line/column)"

echo "==> [17/22] Async rules + worker round trip (PUT /api/rules/printscript/lint -> 202, poll lintStatus)"
LINT_FILE=$(mktemp)
LINT_STATUS_CODE=$(curl -sS -o "${LINT_FILE}" -w "%{http_code}" -X PUT \
  -H "Content-Type: application/json" -H "X-User-Id: ${USER_A}" \
  -d '{"config":{}}' "${BASE_URL}/api/rules/printscript/lint")
if [[ "${LINT_STATUS_CODE}" != "202" ]]; then
  echo "FAIL: Expected HTTP 202 on PUT rules/lint, got ${LINT_STATUS_CODE}: $(cat "${LINT_FILE}")" >&2
  exit 1
fi
py_assert "$(cat "${LINT_FILE}")" "assert data.get('queued', 0) >= 1, f'Expected queued >= 1: {data}'"
rm -f "${LINT_FILE}"
LINT_RESULT=""
for i in $(seq 1 30); do
  LINT_RESULT=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('lintStatus'))")
  if [[ "${LINT_RESULT}" == "COMPLIANT" || "${LINT_RESULT}" == "NON_COMPLIANT" ]]; then
    break
  fi
  sleep 2
done
if [[ "${LINT_RESULT}" != "COMPLIANT" && "${LINT_RESULT}" != "NON_COMPLIANT" ]]; then
  echo "FAIL: lintStatus still '${LINT_RESULT}' after 60s (worker round trip through Redis did not complete)" >&2
  exit 1
fi
echo "PASS (202 queued, lintStatus=${LINT_RESULT} after ~$((i * 2))s)"

echo "==> [18/22] Download: original is exact, formatted works, original preserved"
EXPECTED_ORIGINAL=$'let x: number = 42;\nprintln(x);'
DL_ORIG=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/download")
if [[ "${DL_ORIG}" != "${EXPECTED_ORIGINAL}" ]]; then
  echo "FAIL: Original download differs from uploaded content: ${DL_ORIG}" >&2
  exit 1
fi
DL_FORMATTED=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}/download?formatted=true")
if [[ -z "${DL_FORMATTED}" || "${DL_FORMATTED}" != *"println"* ]]; then
  echo "FAIL: Formatted download unexpected body: ${DL_FORMATTED}" >&2
  exit 1
fi
DETAIL_AFTER=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}")
py_assert "${DETAIL_AFTER}" "assert data['content'] == 'let x: number = 42;\nprintln(x);', f'Stored content changed: {data[\"content\"]!r}'"
echo "PASS"

echo "==> [19/22] Interactive execution over WebSocket (/api/snippets/{id}/run)"
RUN_SNIPPET=$(curl -fsS -X POST \
  -H "Content-Type: application/json" -H "X-User-Id: ${USER_A}" \
  -d '{"name":"e2e-run","language":"printscript","version":"1.1","content":"let name: string = readInput(\"Name?\");\nprintln(\"Hello \" + name);"}' \
  "${BASE_URL}/api/snippets")
RUN_SNIPPET_ID=$(py_assert "${RUN_SNIPPET}" "print(data['id'])")
RUN_SNIPPET_ID_TO_DELETE="${RUN_SNIPPET_ID}"
timeout 150 python3 "$(dirname "${BASH_SOURCE[0]}")/e2e-ws-check.py" "${BASE_URL}" "${RUN_SNIPPET_ID}" "${USER_A}" "e2e-stranger-${RUN_ID}"
curl -sS -o /dev/null -X DELETE -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${RUN_SNIPPET_ID}" || true
RUN_SNIPPET_ID_TO_DELETE=""
echo "PASS (owner run + unauthorized rejected)"

echo "==> [20/22] Revalidate (POST /api/snippets/revalidate -> 202 {queued})"
REV_FILE=$(mktemp)
REV_STATUS=$(curl -sS -o "${REV_FILE}" -w "%{http_code}" -X POST -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/revalidate")
if [[ "${REV_STATUS}" != "202" ]]; then
  echo "FAIL: Expected HTTP 202 on revalidate, got ${REV_STATUS}: $(cat "${REV_FILE}")" >&2
  exit 1
fi
py_assert "$(cat "${REV_FILE}")" "assert isinstance(data.get('queued'), int) and data['queued'] >= 0, f'Unexpected body: {data}'"
rm -f "${REV_FILE}"
echo "PASS (202 queued)"

echo "==> [21/22] Revalidation settles (lintStatus leaves PENDING again)"
REV_LINT=""
for i in $(seq 1 30); do
  REV_LINT=$(curl -fsS -H "X-User-Id: ${USER_A}" "${BASE_URL}/api/snippets/${SNIPPET_ID}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('lintStatus'))")
  if [[ "${REV_LINT}" == "COMPLIANT" || "${REV_LINT}" == "NON_COMPLIANT" ]]; then
    break
  fi
  sleep 2
done
if [[ "${REV_LINT}" != "COMPLIANT" && "${REV_LINT}" != "NON_COMPLIANT" ]]; then
  echo "FAIL: lintStatus still '${REV_LINT}' after revalidation + 60s" >&2
  exit 1
fi
echo "PASS (lintStatus=${REV_LINT})"

echo "==> [22/22] Delete snippet & verify cleanup (DELETE -> 204, subsequent GET -> 403/404)"
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

echo "ALL 22 MULTI-SERVICE E2E CHECKS PASSED against ${BASE_URL}"
