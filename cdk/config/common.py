from dataclasses import dataclass, field

from aws_cdk import aws_ec2 as ec2

from .fargate import MiddlewareServiceFargateStackConfig


@dataclass
class ApiGatewayConfig:
    backend_domain_name: str
    api_certificate_arn: str


@dataclass
class DatabaseConfig:
    instance_type: ec2.InstanceType


@dataclass
class Config:
    git_sha: str
    stage_prefix: str

    # Api Gateway config
    api_gw: ApiGatewayConfig
    frontend_base_url: str

    # Fargate Configuration
    fargate_middleware: MiddlewareServiceFargateStackConfig = field(
        default_factory=lambda: MiddlewareServiceFargateStackConfig()
    )
