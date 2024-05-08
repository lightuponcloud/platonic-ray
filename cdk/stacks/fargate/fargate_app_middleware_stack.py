from os import path

from aws_cdk import (
    core,
    aws_ecs as ecs,
    aws_ec2 as ec2,
    aws_ecs_patterns as ecs_patterns,
    aws_certificatemanager as cert,
    aws_logs as logs
)
from aws_cdk.aws_ecr_assets import DockerImageAsset
from aws_cdk.aws_elasticloadbalancingv2 import ApplicationProtocol, HealthCheck
from constructs import Construct

from config.common import Config

BASE_DIR = path.dirname(path.dirname(path.abspath(__file__)))


class FargateMiddlewareStack(core.Stack):
    """
    Fargate container for Middleware service
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

        self.vpc = vpc

        # Create a cluster
        cluster = ecs.Cluster(self, "fargate-app-middleware-service", vpc=vpc)

        core.Tags.of(cluster).add(config.tag_name, config.tag_value)

        # Logging
        logging = ecs.AwsLogDriver(
            stream_prefix="AppMiddlewareServiceLogs",
            log_group=logs.LogGroup(
                self,
                "FargateMiddlewareLogGroup",
                log_group_name=f"{config.stage_prefix}/MiddlewareService",
            ),
        )

        # Docker image
        asset = DockerImageAsset(
            self,
            "AppMiddlewareServiceDockerImage",
            directory=BASE_DIR + "../../..",
            file="Dockerfile",
        )
        core.Tags.of(asset).add(config.tag_name, config.tag_value)

        # Task definition
        self.task_definition = ecs.FargateTaskDefinition(
            self,
            "TaskDef",
            cpu=config.task_cpu,
            memory_limit_mib=config.task_memory_limit_mib,
        )

        backend_base_url = "https://{}".format(config.backend_domain_name)
        static_base_url = config.static_base_url
        container = self.task_definition.add_container(
            "AppMiddlewareServiceContainer",
            image=ecs.ContainerImage.from_docker_image_asset(asset),
            logging=logging,
            environment={
                "APP_SERVICE_BASE_URL": backend_base_url,
                "STATIC_BASE_URL": static_base_url,
                "APP_SERVICE_KEY": config.app_service_key,
            },
        )

        port_mapping = ecs.PortMapping(container_port=config.container_port, protocol=ecs.Protocol.TCP)
        container.add_port_mappings(port_mapping)

        # Create Fargate Service
        self.fargate_service = ecs_patterns.ApplicationLoadBalancedFargateService(
            self,
            "AppMiddlewareService",
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
                "MiddlewareServiceDomainCertificate",
                certificate_arn=config.elb_certificate_arn,
            )
        )
        self.fargate_service.target_group.configure_health_check(path="/")
        self.fargate_service.service.connections.security_groups[0].add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(443),
            description="Allow http inbound from VPC",
        )
        core.Tags.of(self.fargate_service).add(config.tag_name, config.tag_value)

        self.fargate_service.target_group.configure_health_check(
            path="/riak/health/", healthy_http_codes="200", port="8081",
            interval=core.Duration.minutes(3), timeout=core.Duration.minutes(2))
