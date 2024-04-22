from aws_cdk import core
from constructs import Construct

from config.common import Config
from stacks.api.api_gateway_stack import RestApiStack
from stacks.data.data_stack import DatabaseStack
from stacks.data.queues_stack import RedisStack
from stacks.fargate.fargate_app_scheduler_stack import FargateAppSchedulerServiceStack
from stacks.fargate.fargate_app_stack import FargateAppServiceStack
from stacks.fargate.fargate_app_worker_stack import FargateAppWorkerServiceStack
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

        # Redis queue stack
        self.redis = RedisStack(
            self,
            "RedisStack",
            vpc=self.network.vpc,
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

        # Application services
        self.fargate_app = FargateAppServiceStack(
            self,
            "FargateAppService",
            self.network.vpc,
            self.secrets.app_secrets,
            self.api.api,
            self.redis.redis,
            self.fargate_notification_app.fargate_service,
            config,
        )

        self.fargate_worker = FargateAppWorkerServiceStack(
            self,
            "DataWorkerService",
            self.network.vpc,
            self.secrets.app_secrets,
            self.redis.redis,
            config,
        )

        self.fargate_scheduler = FargateAppSchedulerServiceStack(
            self,
            "DataSchedulerService",
            self.network.vpc,
            self.secrets.app_secrets,
            self.redis.redis,
            config,
        )
