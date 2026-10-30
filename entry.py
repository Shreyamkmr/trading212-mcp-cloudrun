"""
HTTP entrypoint for trading212-mcp-server on Google Cloud Run.

The upstream package only runs over stdio. This wrapper:
  - exposes the server over MCP streamable HTTP
  - serves it only at a secret path: /<MCP_TOKEN>/mcp (everything else 404s)
  - binds to 0.0.0.0:$PORT as Cloud Run requires
  - disables the SDK's localhost-only Host check (otherwise every request gets 421)
  - logs the name of each tool call as structured JSON for Cloud Logging
"""
import json
import os

import uvicorn
from trading212_mcp_server.server import mcp  # importing server registers all tools

TOKEN = os.environ["MCP_TOKEN"]  # container refuses to start without it

mcp.settings.host = "0.0.0.0"
mcp.settings.streamable_http_path = f"/{TOKEN}/mcp"

try:
    from mcp.server.transport_security import TransportSecuritySettings

    mcp.settings.transport_security = TransportSecuritySettings(
        enable_dns_rebinding_protection=False
    )
except Exception:
    pass  # older SDK versions don't have this setting


class ToolLogger:
    """ASGI middleware: logs each MCP tools/call by tool name (never arguments)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("method") != "POST":
            return await self.app(scope, receive, send)

        chunks, more = [], True
        while more:
            msg = await receive()
            chunks.append(msg.get("body", b""))
            more = msg.get("more_body", False)
        body = b"".join(chunks)

        try:
            data = json.loads(body)
            for m in data if isinstance(data, list) else [data]:
                if m.get("method") == "tools/call":
                    print(
                        json.dumps(
                            {
                                "event": "tool_call",
                                "tool": m.get("params", {}).get("name"),
                                "severity": "INFO",
                            }
                        ),
                        flush=True,
                    )
        except Exception:
            pass

        sent = False

        async def replay():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        await self.app(scope, replay, send)


app = ToolLogger(mcp.streamable_http_app())

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
