from aws_cdk import core
from constructs import Construct

from config.common import Config
from stacks.api.api_gateway_stack import RestApiStack
from stacks.data.queues_stack import RedisStack
from stacks.fargate.fargate_app_notifications_stack import FargateNotificationsStack
from stacks.network.network_stack import NetworkStack
from stacks.secrets.stack import SecretsStack
from stacks.static.stack import StaticFilesStack


class DeploymentStage(core.Stage):
    def __init__(self, scope: Construct, construct_id: str, config: Config, **kwargs):
        super().__init__(scope, construct_id, **kwargs)

        # VPC network stack
        self.network = NetworkStack(self, "NetworkStack")

        # Static Files Stack
        self.s3 = StaticFilesStack(
            self,
            "S3UploadBucket",
            config=config,
        )

        # API gateway stack
        self.api = RestApiStack(self, "RestApiStack", config)

        # Notification service
        self.fargate_notification_app = FargateNotificationsStack(
            self,
            "FargateNotificationService",
            self.network.vpc,
            config,
        )
