from aws_cdk import core, aws_s3 as s3, aws_ssm as ssm
from constructs import Construct

from config import Config


class StaticFilesStack(core.Stack):
    def __init__(
        self, scope: Construct, construct_id: str, config: Config, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Create a private bucket
        self.s3_bucket = s3.Bucket(
            self,
            "DataUploadBucket",
            bucket_name=config.upload_s3_bucket_name,
            block_public_access=s3.BlockPublicAccess(
                block_public_acls=True,
                block_public_policy=True,
                ignore_public_acls=True,
                restrict_public_buckets=True,
            ),
            access_control=s3.BucketAccessControl.BUCKET_OWNER_FULL_CONTROL,
            removal_policy=core.RemovalPolicy.DESTROY,  # Delete objects on bucket removal
            auto_delete_objects=True,
        )

        # Save useful parameters to SSM Parameter Store
        self.static_files_bucket_name = ssm.StringParameter(
            self,
            "StaticFilesBucketNameParam",
            parameter_name=f"/{config.stage_prefix}/StaticFilesBucketNameParam",
            string_value=self.s3_bucket.bucket_name,
        )
