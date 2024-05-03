from aws_cdk import core, aws_s3 as s3, aws_ssm as ssm
from constructs import Construct

from config import Config


class S3FilesStack(core.Stack):
    def __init__(
        self, scope: Construct, construct_id: str, config: Config, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.uploads_bucket = self.create_bucket(config, "DataUploadBucket", config.upload_s3_bucket_name)
        self.security_bucket = self.create_bucket(config, "SecurityBucket", config.security_s3_bucket_name)
        self.public_bucket = self.create_bucket(config, "PublicBucket", config.pub_s3_bucket_name)

    def create_bucket(self, config, arn, bucket_name):
        # Create a private bucket
        s3_bucket = s3.Bucket(
            self,
            arn,
            bucket_name=bucket_name,
            block_public_access=s3.BlockPublicAccess(
                block_public_acls=True,
                block_public_policy=True,
                ignore_public_acls=True,
                restrict_public_buckets=True,
            ),
            access_control=s3.BucketAccessControl.BUCKET_OWNER_FULL_CONTROL,
            removal_policy=core.RemovalPolicy.RETAIN,  # Delete objects on bucket removal
            auto_delete_objects=False,
        )

        core.Tags.of(s3_bucket).add(config.tag_name, config.tag_value)

        # Save useful parameters to SSM Parameter Store
        return ssm.StringParameter(
            self,
            "StaticFiles{}Param".format(arn),
            parameter_name="/{}/StaticFiles{}Param".format(config.stage_prefix, arn),
            string_value=s3_bucket.bucket_name,
        )
