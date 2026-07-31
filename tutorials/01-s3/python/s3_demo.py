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
DRAFT_KEY = "drafts/essay.txt"


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

    step("Enabling versioning")
    s3.put_bucket_versioning(
        Bucket=BUCKET,
        VersioningConfiguration={"Status": "Enabled"},
    )

    step("Writing a NEW key twice -- both versions are kept")
    s3.put_object(Bucket=BUCKET, Key=DRAFT_KEY, Body=b"draft one\n")
    s3.put_object(Bucket=BUCKET, Key=DRAFT_KEY, Body=b"draft two\n")
    for v in s3.list_object_versions(Bucket=BUCKET, Prefix="drafts/").get("Versions", []):
        marker = "  <- current" if v["IsLatest"] else ""
        print(f"    {v['Key']}  version={v['VersionId']}{marker}")

    # -----------------------------------------------------------------------
    # The ordering trap. KEY was written before versioning was enabled, so it
    # carries VersionId "null" -- same as real AWS.
    #
    # The divergence is what an overwrite does. Real AWS keeps the null version
    # alongside the new one. Floci 0.2.0 discards it, and the original content
    # becomes unrecoverable. See section 5 of ../README.md.
    # -----------------------------------------------------------------------
    step("The ordering trap: a key written BEFORE versioning was enabled")
    before = s3.list_object_versions(Bucket=BUCKET, Prefix="notes/").get("Versions", [])
    print(f"    before overwrite: {[v['VersionId'] for v in before]}")

    s3.put_object(Bucket=BUCKET, Key=KEY, Body=b"replacement\n")

    after = s3.list_object_versions(Bucket=BUCKET, Prefix="notes/").get("Versions", [])
    print(f"    after overwrite:  {[v['VersionId'] for v in after]}")

    if not any(v["VersionId"] == "null" for v in after):
        print("    the 'null' version is GONE -- the original content is unrecoverable.")
        print("    Real AWS would have kept it. This is a Floci divergence.")
    else:
        print("    the 'null' version survived -- Floci now matches real AWS.")
        print("    The tutorial's section 5 needs updating.")

    versions = s3.list_object_versions(Bucket=BUCKET).get("Versions", [])

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
