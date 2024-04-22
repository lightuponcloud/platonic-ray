from os import path

from aws_cdk import (
    core,
    aws_ecs as ecs,
    aws_ec2 as ec2,
    aws_ecs_patterns as ecs_patterns,
    aws_apigatewayv2 as apigateway,
    aws_apigatewayv2_integrations as integrations,
    aws_elasticache as elc,
    aws_logs as logs,
)
from aws_cdk.aws_ecr_assets import DockerImageAsset
from constructs import Construct

from config.common import Config

BASE_DIR = path.dirname(path.dirname(path.abspath(__file__)))


class FargateAppServiceStack(core.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        vpc: ec2.Vpc,
        secrets: dict,
        api: apigateway.HttpApi,
        redis: elc.CfnCacheCluster,
        fg_notification_service: ecs_patterns.ApplicationLoadBalancedFargateService,
        config: Config,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        fargate_config = config.fargate_app

        self.vpc = vpc
        self.secrets = secrets
        self.api = api
        self.redis = redis
        self.fg_notification_service = fg_notification_service

        # Create a cluster
        cluster = ecs.Cluster(self, "fargate-service-autoscaling", vpc=vpc)

        # Logging
        logging = ecs.AwsLogDriver(
            stream_prefix="AppServiceLogs",
            log_group=logs.LogGroup(
                self,
                "FargateAppServiceLogGroup",
                log_group_name=f"{config.stage_prefix}/AppService",
            ),
        )

        # Docker image
        asset = DockerImageAsset(
            self,
            "AppServiceDockerImage",
            directory=BASE_DIR + "../../../",
            file="Dockerfile",
        )

        # Task definition
        task_definition = ecs.FargateTaskDefinition(
            self,
            "TaskDef",
            cpu=fargate_config.task_cpu,
            memory_limit_mib=fargate_config.task_memory_limit_mib,
        )
        container = task_definition.add_container(
            "AppContainer",
            image=ecs.ContainerImage.from_docker_image_asset(asset),
            logging=logging,
            environment={
                "FLASK_ENV": fargate_config.container_env.flask_env,
                "GUNICORN_NUM_WORKERS": fargate_config.container_env.gunicorn_num_workers,
                "FRONTEND_BASE_URL": config.frontend_base_url,
                "REDIS_ENDPOINT_ADDRESS": self.redis.attr_redis_endpoint_address,
                "AWS_S3_UPLOAD_BUCKET_NAME": config.upload_s3_bucket_name,
                "GIT_COMMIT_ID": config.git_sha or "",
                "NOTIFICATION_SERVICE_DNS": self.fg_notification_service.load_balancer.load_balancer_dns_name,
                "APP_SERVICE_API_KEY": config.fargate_app.app_service_key,
            },
            secrets=self.secrets,
            command=["web"],
        )
        port_mapping = ecs.PortMapping(container_port=5000, protocol=ecs.Protocol.TCP)
        container.add_port_mappings(port_mapping)

        # Create Fargate Service
        self.fargate_service = ecs_patterns.ApplicationLoadBalancedFargateService(
            self,
            "AppService",
            cluster=cluster,
            task_definition=task_definition,
            task_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE),
            public_load_balancer=False,
        )
        self.fargate_service.target_group.configure_health_check(path="/")
        self.fargate_service.service.connections.security_groups[0].add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(80),
            description="Allow http inbound from VPC",
        )

        # Attaching RestApi resources
        self.read_api_gateway_route = apigateway.HttpRoute(
            self,
            "ApiGatewayAppServiceRoute",
            http_api=self.api,
            route_key=apigateway.HttpRouteKey.with_(
                path="/{proxy+}",
                method=apigateway.HttpMethod.ANY,
            ),
            integration=integrations.HttpAlbIntegration(
                "APIGWHttpAlbIntegration",
                listener=self.fargate_service.listener,
                method=apigateway.HttpMethod.ANY,
                vpc_link=apigateway.VpcLink(
                    self,
                    "VpcLink",
                    vpc=self.vpc,
                    subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE),
                    vpc_link_name="VpcLink",
                ),
            ),
        )

        core.CfnOutput(
            self,
            "LoadBalancerDNS",
            value=self.fargate_service.load_balancer.load_balancer_dns_name,
        )
