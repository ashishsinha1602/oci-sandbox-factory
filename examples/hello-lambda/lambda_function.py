"""An ordinary AWS Lambda handler (API Gateway proxy style), unchanged.

Sandbox Factory runs it as an OCI Function: point the assistant at this folder
and ask for "an OCI function". It wraps the handler in an adapter and builds
the image inside OCI; no Dockerfile needed.
"""
import json


def lambda_handler(event, context):
    body = event.get("body") if isinstance(event, dict) else None
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except ValueError:
            body = {}
    name = (body or event or {}).get("name", "world") if isinstance(body or event, dict) else "world"
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": f"hello {name}", "from": "aws-lambda-code-on-oci-functions",
                            "request_id": context.aws_request_id}),
    }
