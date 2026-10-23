import os

# Before boto3 is used: fake credentials, and no EC2 metadata lookups. Without
# this boto3 would find the real instance role (or hang without a network).
os.environ.update(
    AWS_ACCESS_KEY_ID="testing",
    AWS_SECRET_ACCESS_KEY="testing",
    AWS_SESSION_TOKEN="testing",
    AWS_DEFAULT_REGION="ap-south-1",
    AWS_EC2_METADATA_DISABLED="true",
)
