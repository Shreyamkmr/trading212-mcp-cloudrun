FROM python:3.11-slim

# uv for fast installs
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Unbuffered output so logs reach Cloud Logging immediately
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# mcp<2: the server imports mcp.server.fastmcp, which was renamed in mcp 2.x.
# --compile-bytecode: faster cold starts.
RUN uv pip install --system --compile-bytecode \
    "trading212-mcp-server==0.4.0" \
    "mcp<2" \
    uvicorn

COPY entry.py .

EXPOSE 8080
CMD ["python", "entry.py"]
