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

import boto3  # noqa: E402
import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from moto import mock_aws  # noqa: E402

from reelops_api.config import Settings  # noqa: E402
from reelops_api.jobs import make_s3_client  # noqa: E402
from reelops_api.main import create_app  # noqa: E402

REGION = "ap-south-1"


@pytest.fixture
def settings():
    return Settings(media_bucket="reelops-media-test", jobs_table="reelops-test-jobs", aws_region=REGION)


@pytest.fixture
def aws(settings):
    """Moto bucket + table shaped like terraform/main."""
    with mock_aws():
        s3 = make_s3_client(REGION)
        s3.create_bucket(Bucket=settings.media_bucket, CreateBucketConfiguration={"LocationConstraint": REGION})
        dynamodb = boto3.resource("dynamodb", region_name=REGION)
        table = dynamodb.create_table(
            TableName=settings.jobs_table,
            KeySchema=[{"AttributeName": "job_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "job_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield s3, table


@pytest.fixture
def client(settings, aws):
    s3, table = aws
    return TestClient(create_app(settings, s3=s3, table=table))


@pytest.fixture
def table(aws):
    return aws[1]
