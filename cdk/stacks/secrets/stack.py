from aws_cdk import (
    core,
    aws_ecs as ecs,
    aws_secretsmanager as secretsmanager,
)
from constructs import Construct

from config import Config


class SecretsStack(core.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        database_secrets: secretsmanager.ISecret,
        config: Config,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Secret values required by the app which are store in the Secrets Manager
        # This values will be injected as env vars on runtime
        self.app_secrets = {
            # AWS account secrets
            "AWS_ACCESS_KEY_ID": ecs.Secret.from_secrets_manager(
                secretsmanager.Secret.from_secret_name_v2(
                    self,
                    "AWSAccessKeyIDSecret",
                    secret_name=f"/{config.stage_prefix}/AwsApiKeyId",
                )
            ),
            "AWS_SECRET_ACCESS_KEY": ecs.Secret.from_secrets_manager(
                secretsmanager.Secret.from_secret_name_v2(
                    self,
                    "AWSAccessKeySecretSecret",
                    secret_name=f"/{config.stage_prefix}/AwsApiKeySecret",
                )
            )
        }
