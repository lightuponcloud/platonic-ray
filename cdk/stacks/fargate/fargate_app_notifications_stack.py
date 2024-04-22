from os import path

from aws_cdk import (
    core,
    aws_ecs as ecs,
    aws_ec2 as ec2,
    aws_ecs_patterns as ecs_patterns,
    aws_certificatemanager as cert,
    aws_logs as logs,
)
from aws_cdk.aws_ecr_assets import DockerImageAsset
from aws_cdk.aws_elasticloadbalancingv2 import ApplicationProtocol
from constructs import Construct

from config.common import Config

BASE_DIR = path.dirname(path.dirname(path.abspath(__file__)))


class FargateNotificationsStack(core.Stack):
    """
    Fargate container for PubSub notifications service
    """

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        vpc: ec2.Vpc,
        config: Config,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        fargate_config = config.fargate_notifications

        self.vpc = vpc

        # Create a cluster
        cluster = ecs.Cluster(self, "fargate-app-notifications-service", vpc=vpc)

        # Logging
        logging = ecs.AwsLogDriver(
            stream_prefix="AppNotificationsServiceLogs",
            log_group=logs.LogGroup(
                self,
                "FargateNotificationsLogGroup",
                log_group_name=f"{config.stage_prefix}/NotificationService",
            ),
        )

        # Docker image
        asset = DockerImageAsset(
            self,
            "AppNotificationsServiceDockerImage",
            directory=BASE_DIR + "../../../pubsub/",
            file="Dockerfile",
        )

        # Task definition
        self.task_definition = ecs.FargateTaskDefinition(
            self,
            "TaskDef",
            cpu=fargate_config.task_cpu,
            memory_limit_mib=fargate_config.task_memory_limit_mib,
        )
        container = self.task_definition.add_container(
            "AppNotificationsServiceContainer",
            image=ecs.ContainerImage.from_docker_image_asset(asset),
            logging=logging,
            environment={
                "APP_SERVICE_BASE_URL": config.get_backend_base_url(),
                "APP_SERVICE_KEY": config.fargate_app.app_service_key,
            },
        )
        port_mapping = ecs.PortMapping(container_port=8082, protocol=ecs.Protocol.TCP)
        container.add_port_mappings(port_mapping)

        # Create Fargate Service
        self.fargate_service = ecs_patterns.ApplicationLoadBalancedFargateService(
            self,
            "AppNotificationsService",
            cluster=cluster,
            task_definition=self.task_definition,
            task_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE),
            public_load_balancer=True,
            # HTTPS Listeners configuration
            listener_port=443,
            protocol=ApplicationProtocol.HTTPS,
            redirect_http=True,
            certificate=cert.Certificate.from_certificate_arn(
                self,
                "NotificationServiceDomainCertificate",
                certificate_arn=config.fargate_notifications.elb_certificate_arn,
            ),
        )
        self.fargate_service.target_group.configure_health_check(path="/")
        self.fargate_service.service.connections.security_groups[0].add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(443),
            description="Allow http inbound from VPC",
        )
