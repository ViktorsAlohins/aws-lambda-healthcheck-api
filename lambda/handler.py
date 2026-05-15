import json
import os
import time
import uuid
import boto3

table_name = os.environ["requests_table"]
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(table_name)


def handler(event, context):
    print("incoming event:")
    print(json.dumps(event))

    request_context = event.get("requestContext", {})
    http = request_context.get("http", {})
    method = http.get("method", "unknown")

    body = {}

    if method == "POST":
        raw_body = event.get("body")

        if not raw_body:
            return {
                "statusCode": 400,
                "headers": {
                    "content-type": "application/json"
                },
                "body": json.dumps({
                    "error": "missing request body"
                })
            }

        try:
            body = json.loads(raw_body)
        except json.JSONDecodeError:
            return {
                "statusCode": 400,
                "headers": {
                    "content-type": "application/json"
                },
                "body": json.dumps({
                    "error": "invalid json body"
                })
            }

        if "payload" not in body:
            return {
                "statusCode": 400,
                "headers": {
                    "content-type": "application/json"
                },
                "body": json.dumps({
                    "error": "missing payload"
                })
            }

    item = {
        "id": str(uuid.uuid4()),
        "created_at": int(time.time()),
        "method": method,
        "path": event.get("rawPath", "/"),
        "source_ip": http.get("sourceIp", "unknown"),
        "user_agent": event.get("headers", {}).get("user-agent", "unknown"),
        "payload": json.dumps(body.get("payload", ""))
    }

    table.put_item(Item=item)

    return {
        "statusCode": 200,
        "headers": {
            "content-type": "application/json"
        },
        "body": json.dumps({
            "status": "healthy",
            "message": "Request processed and saved."
        })
    }