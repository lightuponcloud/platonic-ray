from os import path

from aws_cdk import (
    core,
    aws_ecs as ecs,
    aws_ec2 as ec2,
    aws_elasticache as elc,
    aws_logs as logs,
)
from aws_cdk.aws_ecr_assets import DockerImageAsset
from constructs import Construct

from config.common import Config

BASE_DIR = path.dirname(path.dirname(path.abspath(__file__)))


class FargateAppSchedulerServiceStack(core.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        vpc: ec2.Vpc,
        secrets: dict,
        redis: elc.CfnCacheCluster,
        config: Config,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        fargate_config = config.fargate_scheduler

        self.vpc = vpc
        self.secrets = secrets
        self.redis = redis

        # Create a cluster
        cluster = ecs.Cluster(self, "fargate-app-scheduler-service", vpc=vpc)

        # Logging
        logging = ecs.AwsLogDriver(
            stream_prefix="AppSchedulerServiceLogs",
            log_group=logs.LogGroup(
                self,
                "FargateAppSchedulerServiceLogGroup",
                log_group_name=f"{config.stage_prefix}/SchedulerService",
            ),
        )

        # Docker image
        asset = DockerImageAsset(
            self,
            "AppSchedulerServiceDockerImage",
            directory=BASE_DIR + "../../../",
            file="Dockerfile",
        )

        # Task definition
        self.task_definition = ecs.FargateTaskDefinition(
            self,
            "TaskDef",
            cpu=fargate_config.task_cpu,
            memory_limit_mib=fargate_config.task_memory_limit_mib,
        )
        self.container = self.task_definition.add_container(
            "AppSchedulerServiceContainer",
            image=ecs.ContainerImage.from_docker_image_asset(asset),
            logging=logging,
            environment={
                "FLASK_ENV": fargate_config.container_env.flask_env,
                "FRONTEND_BASE_URL": config.frontend_base_url,
                "REDIS_ENDPOINT_ADDRESS": self.redis.attr_redis_endpoint_address,
                "AWS_S3_UPLOAD_BUCKET_NAME": config.upload_s3_bucket_name,
            },
            secrets=self.secrets,
            command=["scheduler"],
        )
        self.scheduler_service = ecs.FargateService(
            self,
            "SchedulerService",
            service_name="scheduler",
            cluster=cluster,
            # Can't use isolated because it will not be able to retrieve db secrets
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE),
            task_definition=self.task_definition,
            desired_count=1,
            assign_public_ip=False,
        )
