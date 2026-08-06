"""
IAM, STS, Secrets Manager and KMS against Floci, using boto3.

    pip install -r requirements.txt
    python iam_demo.py

This script proves two things that matter more than the API calls themselves:
the policy is ignored on real requests, and the simulator evaluates the very
same policy correctly.
"""

import base64
import json
import os

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# The ONLY Floci-specific lines. Delete endpoint_url and this runs on real AWS.
# ---------------------------------------------------------------------------
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
COMMON = dict(
    endpoint_url=ENDPOINT,
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)

iam = boto3.client("iam", **COMMON)
sts = boto3.client("sts", **COMMON)
secrets = boto3.client("secretsmanager", **COMMON)
kms = boto3.client("kms", **COMMON)
s3 = boto3.client("s3", **COMMON)

ROLE = "demo-app-role"
BUCKET = "demo-enforcement-test"
SECRET = "demo-db-credentials"
ACCOUNT = "000000000000"

TRUST = {
    "Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Principal": {"AWS": "*"}, "Action": "sts:AssumeRole"}
    ],
}
PERMS = {
    "Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "*"},
        {"Effect": "Deny", "Action": "s3:DeleteObject", "Resource": "*"},
    ],
}


def step(msg):
    print(f"\n==> {msg}")


def cleanup():
    try:
        iam.delete_role_policy(RoleName=ROLE, PolicyName="perms")
    except ClientError:
        pass
    try:
        iam.delete_role(RoleName=ROLE)
    except ClientError:
        pass
    try:
        objs = s3.list_objects_v2(Bucket=BUCKET).get("Contents", [])
        for o in objs:
            s3.delete_object(Bucket=BUCKET, Key=o["Key"])
        s3.delete_bucket(Bucket=BUCKET)
    except ClientError:
        pass
    try:
        secrets.delete_secret(SecretId=SECRET, ForceDeleteWithoutRecovery=True)
    except ClientError:
        pass


def main():
    cleanup()

    step(f"Creating role {ROLE}")
    # A trust policy says WHO may assume the role. A permission policy says
    # WHAT the role may then do. Mixing them up is the classic beginner error.
    iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(TRUST))
    iam.put_role_policy(
        RoleName=ROLE, PolicyName="perms", PolicyDocument=json.dumps(PERMS)
    )
    print("    policy allows s3:GetObject and explicitly denies s3:DeleteObject")

    step("Assuming the role")
    creds = sts.assume_role(
        RoleArn=f"arn:aws:iam::{ACCOUNT}:role/{ROLE}",
        RoleSessionName="my-session",
    )["Credentials"]
    print(f"    expires: {creds['Expiration']}")

    assumed = dict(
        COMMON,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )
    who = boto3.client("sts", **assumed).get_caller_identity()["Arn"]
    # Note the session name in this ARN. It says floci-session, not my-session.
    print(f"    identity: {who}")

    step("Testing whether the Deny is enforced")
    s3.create_bucket(Bucket=BUCKET)
    s3.put_object(Bucket=BUCKET, Key="f.txt", Body=b"delete me\n")

    s3_assumed = boto3.client("s3", **assumed)
    try:
        s3_assumed.delete_object(Bucket=BUCKET, Key="f.txt")
        print("    delete SUCCEEDED, even though the policy explicitly denies it")
        print("    the policy was stored, and never consulted")
    except ClientError as e:
        print(f"    delete was denied: {e.response['Error']['Code']}")
        print("    Floci now enforces IAM, and this tutorial needs rewriting")

    step("Trying credentials that were never issued by anything")
    invented = dict(
        COMMON,
        aws_access_key_id="AKIAFAKEFAKEFAKE",
        aws_secret_access_key="nonsense",
    )
    try:
        boto3.client("s3", **invented).list_buckets()
        print("    accepted, so any credential works here")
    except ClientError as e:
        print(f"    rejected: {e.response['Error']['Code']}")

    step("The simulator, which does evaluate the same policy correctly")
    for action, resource in [
        ("s3:GetObject", f"arn:aws:s3:::{BUCKET}/f.txt"),
        ("s3:DeleteObject", f"arn:aws:s3:::{BUCKET}/f.txt"),
        ("ec2:TerminateInstances", "*"),
    ]:
        result = iam.simulate_principal_policy(
            PolicySourceArn=f"arn:aws:iam::{ACCOUNT}:role/{ROLE}",
            ActionNames=[action],
            ResourceArns=[resource],
        )["EvaluationResults"][0]
        print(f"    {action:<26} {result['EvalDecision']}")

    print("\n    allowed      = something granted it and nothing denied it")
    print("    explicitDeny = a Deny matched, and Deny always wins")
    print("    implicitDeny = nothing mentioned it, so it is denied by default")

    step("Secrets Manager, which works properly")
    secrets.create_secret(
        Name=SECRET, SecretString=json.dumps({"user": "admin", "pass": "s3cret"})
    )
    print(f"    current:  {secrets.get_secret_value(SecretId=SECRET)['SecretString']}")

    secrets.put_secret_value(
        SecretId=SECRET, SecretString=json.dumps({"user": "admin", "pass": "rotated"})
    )
    print(f"    rotated:  {secrets.get_secret_value(SecretId=SECRET)['SecretString']}")
    # Version staging is what makes safe rotation possible: roll back by moving
    # a label rather than by restoring a backup.
    previous = secrets.get_secret_value(SecretId=SECRET, VersionStage="AWSPREVIOUS")
    print(f"    previous: {previous['SecretString']}")

    step("KMS, which does NOT encrypt")
    key_id = kms.create_key(Description="demo")["KeyMetadata"]["KeyId"]
    plaintext = b"ATTACK_AT_DAWN"
    blob = kms.encrypt(KeyId=key_id, Plaintext=plaintext)["CiphertextBlob"]

    decoded = blob.decode() if isinstance(blob, bytes) else str(blob)
    print(f"    ciphertext envelope: {decoded[:90]}")

    # The final field of the envelope is ordinary base64. No key required.
    tail = decoded.rsplit(":", 1)[-1]
    try:
        recovered = base64.b64decode(tail)
        if recovered == plaintext:
            print(f"    recovered without any key: {recovered.decode()}")
            print("    nothing you put through KMS here is protected")
    except Exception:
        print("    could not decode the tail; Floci may now encrypt properly")

    step("Cleaning up")
    cleanup()
    print("    done")


if __name__ == "__main__":
    main()
