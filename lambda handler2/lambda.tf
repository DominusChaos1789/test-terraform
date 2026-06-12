"""
Local test runner for lambda_handler.py — NO AWS calls.

Mocks boto3 clients (sqs.send_message / s3.put_object) so you can run
the handler logic on your machine and see exactly what it would do.

Usage:
    pip install boto3 --break-system-packages   # only needed for the real import
    python run_local.py event_details.json
    python run_local.py event_summary.json
    python run_local.py event_bad.json
"""

import sys
import json
import os
from unittest.mock import patch, MagicMock

# --- Fake env vars (so os.environ[...] doesn't crash) -----------------------
os.environ["SQS_QUEUE_URL"] = "https://sqs.fake/123/queue"
os.environ["S3_BUCKET"]     = "landing-fake"
os.environ["S3_PREFIX"]     = "transcripts"


def main():
    if len(sys.argv) < 2:
        print("Usage: python run_local.py <event_file.json>")
        sys.exit(1)

    event_file = sys.argv[1]
    with open(event_file, "r", encoding="utf-8") as f:
        event = json.load(f)

    # --- Mock boto3.client so no real AWS calls happen ----------------------
    mock_sqs = MagicMock()
    mock_sqs.send_message.return_value = {"MessageId": "local-fake-id-123"}

    mock_s3 = MagicMock()
    mock_s3.put_object.return_value = {}

    def fake_client(service_name, *args, **kwargs):
        if service_name == "sqs":
            return mock_sqs
        if service_name == "s3":
            return mock_s3
        return MagicMock()

    with patch("boto3.client", side_effect=fake_client):
        # Import AFTER patching so the module-level boto3.client() calls
        # inside lambda_handler.py pick up the mocks
        import lambda_handler
        result = lambda_handler.lambda_handler(event, context={})

    # --- Print results --------------------------------------------------------
    print("\n=== Lambda Response ===")
    print(json.dumps(result, indent=2, ensure_ascii=False))

    print("\n=== Mocked SQS send_message calls ===")
    for call in mock_sqs.send_message.call_args_list:
        print(json.dumps(call.kwargs, indent=2, ensure_ascii=False))

    print("\n=== Mocked S3 put_object calls ===")
    for call in mock_s3.put_object.call_args_list:
        kw = dict(call.kwargs)
        # Body might be large — pretty print it
        if "Body" in kw:
            try:
                kw["Body"] = json.loads(kw["Body"])
            except Exception:
                pass
        print(json.dumps(kw, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
