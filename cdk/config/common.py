from dataclasses import dataclass

from aws_cdk import aws_ec2 as ec2

from .fargate import (
    AppFargateStackConfig,
    WorkerFargateStackConfig,
    SchedulerFargateStackConfig,
    NotificationServiceFargateStackConfig,
)


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

    # Database config
    database: DatabaseConfig

    # Fargate Configuration
    fargate_app: AppFargateStackConfig = AppFargateStackConfig()
    fargate_worker: WorkerFargateStackConfig = WorkerFargateStackConfig()
    fargate_scheduler: SchedulerFargateStackConfig = SchedulerFargateStackConfig()
    fargate_notifications: NotificationServiceFargateStackConfig = (
        NotificationServiceFargateStackConfig()
    )

    def get_backend_base_url(self):
        return f"https://{self.api_gw.backend_domain_name}"

    @property
    def upload_s3_bucket_name(self):
        return f"{self.stage_prefix}-data-service-uploaded-files".lower()
