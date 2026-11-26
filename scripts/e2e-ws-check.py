#!/usr/bin/env python3
"""E2E check of the interactive execution WebSocket (US10).

Usage: e2e-ws-check.py <http-base-url> <snippet-id> <owner-id> <stranger-id>

Case 1: the owner runs a PrintScript 1.1 snippet that uses readInput + println.
        Expects input-request -> (we send input) -> output -> finished -> close 1000.
Case 2: a user without access gets a rejected handshake or close 1008.
Requires the `websockets` package (pip install websockets).
"""
import asyncio
import json
import sys
from urllib.parse import quote, urlparse

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

TIMEOUT = 45


def ws_url(base, snippet_id, user):
    parsed = urlparse(base)
    scheme = "wss" if parsed.scheme == "https" else "ws"
    return f"{scheme}://{parsed.netloc}/api/snippets/{snippet_id}/run?userId={quote(user)}"


async def owner_case(url):
    outputs, got_request, finished = [], False, False
    async with connect(url, open_timeout=TIMEOUT) as ws:
        while True:
            try:
                raw = await asyncio.wait_for(ws.recv(), TIMEOUT)
            except ConnectionClosed:
                break
            msg = json.loads(raw)
            kind = msg.get("type")
            if kind == "input-request":
                got_request = True
                await ws.send(json.dumps({"type": "input", "value": "Bob"}))
            elif kind == "output":
                outputs.append(str(msg.get("value", "")))
            elif kind == "finished":
                finished = True
            elif kind == "error":
                raise AssertionError(f"unexpected error message: {msg}")
        code = ws.close_code
    assert got_request, "no input-request received"
    assert any("Hello Bob" in o for o in outputs), f"missing 'Hello Bob' in outputs {outputs}"
    assert finished, "no finished message received"
    assert code == 1000, f"expected close code 1000, got {code}"
    return outputs


async def stranger_case(url):
    try:
        async with connect(url, open_timeout=TIMEOUT) as ws:
            try:
                while True:
                    msg = json.loads(await asyncio.wait_for(ws.recv(), TIMEOUT))
                    assert msg.get("type") not in ("output", "input-request", "finished"), (
                        f"stranger received execution data: {msg}"
                    )
            except ConnectionClosed:
                pass
            assert ws.close_code == 1008, f"expected close 1008, got {ws.close_code}"
            return "close 1008"
    except InvalidStatus as e:
        status = e.response.status_code
        assert status in (401, 403, 404), f"unexpected handshake status {status}"
        return f"handshake rejected with HTTP {status}"


def main():
    base, snippet_id, owner, stranger = sys.argv[1:5]
    failed = False
    try:
        outputs = asyncio.run(owner_case(ws_url(base, snippet_id, owner)))
        print(f"PASS ws owner: input-request, outputs={outputs}, finished, close 1000")
    except Exception as e:  # noqa: BLE001
        failed = True
        print(f"FAIL ws owner: {type(e).__name__}: {e}")
    try:
        result = asyncio.run(stranger_case(ws_url(base, snippet_id, stranger)))
        print(f"PASS ws stranger: {result}")
    except Exception as e:  # noqa: BLE001
        failed = True
        print(f"FAIL ws stranger: {type(e).__name__}: {e}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
