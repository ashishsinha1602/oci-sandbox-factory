"""The smallest OCI Function: echoes a greeting. Built by the factory into a
function image; the sandbox gives it a plain HTTPS URL through its gateway."""
import io
import json

from fdk import response


def handler(ctx, data: io.BytesIO = None):
    name = "world"
    try:
        body = json.loads(data.getvalue() or b"{}")
        name = body.get("name") or name
    except Exception:  # noqa: BLE001
        pass
    return response.Response(ctx, response_data=json.dumps({"message": f"hello {name}", "from": "oci-function"}),
                             headers={"Content-Type": "application/json"})
