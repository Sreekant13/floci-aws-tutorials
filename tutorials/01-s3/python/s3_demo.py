"""
S3 against Floci, using boto3.

Does the same sequence as the CLI walkthrough in ../README.md:
create -> upload -> presign -> fetch anonymously -> version -> clean up.

    pip install -r requirements.txt
    python s3_demo.py
"""

import os
import urllib.request

import boto3

# ---------------------------------------------------------------------------
# The ONLY Floci-specific line in this file.
#
# Delete endpoint_url and this exact script runs against real AWS, using
# whatever credentials your environment already has. Everything below is
# ordinary boto3.
# ---------------------------------------------------------------------------
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")

s3 = boto3.client(
    "s3",
    endpoint_url=ENDPOINT,
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)

BUCKET = "floci-demo-python"
KEY = "notes/sample.txt"


def step(msg):
    print(f"\n==> {msg}")


def main():
    step(f"Creating bucket {BUCKET}")
    try:
        s3.create_bucket(Bucket=BUCKET)
    except s3.exceptions.BucketAlreadyOwnedByYou:
        print("    already exists, reusing it")

    step("Uploading an object")
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=b"the quick brown fox\n")

    step("Listing with a prefix")
    listing = s3.list_objects_v2(Bucket=BUCKET, Prefix="notes/")
    for obj in listing.get("Contents", []):
        print(f"    {obj['Key']}  ({obj['Size']} bytes)")

    step("Reading it back")
    body = s3.get_object(Bucket=BUCKET, Key=KEY)["Body"].read().decode()
    print(f"    {body.strip()!r}")

    step("Generating a presigned URL (valid 5 minutes)")
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": BUCKET, "Key": KEY},
        ExpiresIn=300,
    )
    print(f"    {url}")

    step("Fetching that URL with no credentials at all")
    # urllib knows nothing about AWS. The signature in the query string is the
    # entire authorisation -- that is the point of a presigned URL.
    with urllib.request.urlopen(url, timeout=10) as resp:
        print(f"    HTTP {resp.status}: {resp.read().decode().strip()!r}")

    step("Enabling versioning and overwriting")
    s3.put_bucket_versioning(
        Bucket=BUCKET,
        VersioningConfiguration={"Status": "Enabled"},
    )
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=b"jumps over the lazy dog\n")

    versions = s3.list_object_versions(Bucket=BUCKET, Prefix="notes/").get("Versions", [])
    for v in versions:
        marker = "  <- current" if v["IsLatest"] else ""
        print(f"    {v['Key']}  version={v['VersionId']}{marker}")

    step("Cleaning up")
    # A versioned bucket needs every version removed before it will delete.
    for v in versions:
        s3.delete_object(Bucket=BUCKET, Key=v["Key"], VersionId=v["VersionId"])
    for m in s3.list_object_versions(Bucket=BUCKET).get("DeleteMarkers", []):
        s3.delete_object(Bucket=BUCKET, Key=m["Key"], VersionId=m["VersionId"])
    s3.delete_bucket(Bucket=BUCKET)
    print("    done")


if __name__ == "__main__":
    main()
