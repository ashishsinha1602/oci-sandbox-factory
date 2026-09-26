# schemagate MCP server (streamable-http) reflecting the sandbox's Autonomous Database.
# The sandbox injects ADB_CONNECT_STRING / ADB_ADMIN_PASSWORD; entrypoint.py turns them
# into SCHEMAGATE_DATABASE_URL + SCHEMAGATE_CONNECT_ARGS (TLS descriptor, no wallet).
FROM python:3.12-slim
RUN pip install --no-cache-dir "schemagate[oracle,mcp]"
COPY entrypoint.py /entrypoint.py
ENV SCHEMAGATE_MCP_TRANSPORT=streamable-http \
    SCHEMAGATE_MCP_HOST=0.0.0.0 \
    SCHEMAGATE_MCP_PORT=8765 \
    SCHEMAGATE_CATALOG_CONFIG=/data/catalog.json
RUN mkdir -p /data && echo '{"restrict": {}, "hint": {}, "describe": {}}' > /data/catalog.json
EXPOSE 8765
CMD ["python", "/entrypoint.py"]
