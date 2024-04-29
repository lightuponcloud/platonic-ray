#!/usr/bin/env python3
import os

from aws_cdk import (
    core,
    aws_ec2 as ec2,
)

from config import (
    Config,
    NotificationServiceFargateStackConfig,
    ApiGatewayConfig,
    ContainerEnv,
)

from stacks.deployment_stage import DeploymentStage


app = core.App()
CDK_DEFAULT_ACCOUNT = "<< REPLACE ME >>"
CDK_DEFAULT_REGION = "us-east-2"

config = NotificationServiceFargateStackConfig()
config.upload_s3_bucket_name = "<< REPLACE ME >>"
config.stage_prefix = ""
config.api_certificate_arn = "<< REPLACE ME >>"
config.backend_domain_name = "<< REPLACE ME >>"
config.frontend_base_url = "<< REPLACE ME >>"
config.app_service_key = "<< REPLACE ME >>"
config.elb_certificate_arn = "<< REPLACE ME >>"

DeploymentStage(app, "DeploymentStage", config)

app.synth()
