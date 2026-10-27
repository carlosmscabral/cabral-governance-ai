#!/usr/bin/env python3
"""Connects to the deployed Streamable HTTP MCP server over JSON-RPC and writes toolspec.json
formatted for Vertex AI Agent Registry (--mcp-server-spec-type=tool-spec).
"""

import argparse
import json
import sys
import urllib.request


def rpc_post(url: str, token: str, method: str, params: dict | None = None, session_id: str | None = None):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        payload["params"] = params

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if session_id:
        headers["Mcp-Session-Id"] = session_id

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        new_session = resp.headers.get("mcp-session-id") or session_id
        raw = resp.read().decode("utf-8")

    json_str = ""
    for line in raw.splitlines():
        if line.startswith("data: "):
            json_str = line[6:]
            break
    if not json_str:
        json_str = raw

    body = json.loads(json_str)
    if "error" in body:
        raise RuntimeError(f"MCP JSON-RPC error on {method}: {body['error']}")
    return body.get("result", {}), new_session


def extract_bool(annotations: dict, tool_obj: dict, hint_key: str, reg_key: str, default: bool) -> bool:
    if hint_key in annotations and annotations[hint_key] is not None:
        return bool(annotations[hint_key])
    short_key = hint_key.replace("Hint", "")
    if short_key in annotations and annotations[short_key] is not None:
        return bool(annotations[short_key])
    if reg_key in tool_obj and tool_obj[reg_key] is not None:
        return bool(tool_obj[reg_key])
    return default


def main():
    parser = argparse.ArgumentParser(description="Generate Agent Registry toolspec.json from live MCP server")
    parser.add_argument("--mcp-url", required=True, help="Full MCP endpoint URL (e.g. https://.../mcp)")
    parser.add_argument("--token", default="", help="Bearer OIDC ID token for Cloud Run authentication")
    parser.add_argument("--output", required=True, help="Path to write toolspec.json")
    args = parser.parse_args()

    _, session_id = rpc_post(
        args.mcp_url,
        args.token,
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "agent-registry-toolspec-generator", "version": "1.0.0"},
        },
    )

    result, _ = rpc_post(args.mcp_url, args.token, "tools/list", session_id=session_id)
    raw_tools = result.get("tools", [])
    if not raw_tools:
        print("ERROR: MCP server returned 0 tools.", file=sys.stderr)
        sys.exit(1)

    spec_tools = []
    for t in raw_tools:
        ann = t.get("annotations") or {}
        input_schema = t.get("inputSchema") or {"type": "object", "properties": {}}
        is_read_only = extract_bool(ann, t, "readOnlyHint", "isReadOnly", False)
        is_destructive = extract_bool(ann, t, "destructiveHint", "isDestructive", not is_read_only)
        is_idempotent = extract_bool(ann, t, "idempotentHint", "isIdempotent", is_read_only)
        is_open_world = extract_bool(ann, t, "openWorldHint", "isOpenWorld", False)

        spec_tools.append(
            {
                "name": t["name"],
                "description": t.get("description", ""),
                "inputSchema": input_schema,
                "annotations": {
                    "readOnlyHint": is_read_only,
                    "destructiveHint": is_destructive,
                    "idempotentHint": is_idempotent,
                    "openWorldHint": is_open_world,
                },
            }
        )

    output_doc = {"tools": spec_tools}
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(output_doc, f, ensure_ascii=False, indent=2)

    print(f"Generated {args.output} with {len(spec_tools)} tools:")
    for item in spec_tools:
        a = item["annotations"]
        print(
            f"  - {item['name']}: readOnlyHint={a['readOnlyHint']}, "
            f"destructiveHint={a['destructiveHint']}, idempotentHint={a['idempotentHint']}"
        )


if __name__ == "__main__":
    main()
