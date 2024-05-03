from aws_cdk import core
from constructs import Construct

from config.common import Config
from stacks.api.api_gateway_stack import RestApiStack
from stacks.data.queues_stack import RedisStack
from stacks.fargate.fargate_app_middleware_stack import FargateMiddlewareStack
from stacks.network.network_stack import NetworkStack
from stacks.secrets.stack import SecretsStack
from stacks.static.stack import S3FilesStack


class DeploymentStage(core.Stage):
    def __init__(self, scope: Construct, construct_id: str, config: Config, **kwargs):
        super().__init__(scope, construct_id, **kwargs)

        # VPC network stack
        self.network = NetworkStack(self, "NetworkStack")

        # Static Files Stack
        self.s3_static = S3FilesStack(
            self,
            "S3UploadBucket",
            config=config,
        )

        # API gateway stack
        self.api = RestApiStack(self, "RestApiStack", config)

        # Middleware service
        self.fargate_middleware_app = FargateMiddlewareStack(
            self,
            "FargateMiddlewareService",
            self.network.vpc,
            config,
        )
