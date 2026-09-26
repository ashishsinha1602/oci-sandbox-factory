# schemagate Studio (web page) on the sandbox's Autonomous Database, port 8770.
# The sandbox injects ADB_CONNECT_STRING / ADB_ADMIN_PASSWORD; entrypoint.py maps them
# to SCHEMAGATE_DATABASE_URL + SCHEMAGATE_CONNECT_ARGS and seeds a small demo schema
# when the database is empty (set SEED_DEMO=no to skip).
FROM python:3.12-slim
RUN pip install --no-cache-dir "schemagate[oracle,mcp]"
COPY entrypoint.py /entrypoint.py
ENV STUDIO_PORT=8770
EXPOSE 8770
CMD ["python", "/entrypoint.py"]
