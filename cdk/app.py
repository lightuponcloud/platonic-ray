#!/usr/bin/env python3
import os

from aws_cdk import (
    core,
    aws_ec2 as ec2,
)

from config import (
    Config,
    MiddlewareServiceFargateStackConfig,
    ApiGatewayConfig,
    ContainerEnv,
)

from stacks.deployment_stage import DeploymentStage


app = core.App()
CDK_DEFAULT_ACCOUNT = "<< REPLACE ME >>"
CDK_DEFAULT_REGION = "us-east-2"

CERT_ARN = "<< REPLACE ME >>"

config = MiddlewareServiceFargateStackConfig()

config.upload_s3_bucket_name = "<< REPLACE ME >>"
config.security_s3_bucket_name = "<< REPLACE ME >>"
config.pub_s3_bucket_name = "<< REPLACE ME >>"

config.tag_name = "<< REPLACE ME >>"
config.tag_value = "<< REPLACE ME >>"

config.stage_prefix = "staging"
config.api_certificate_arn = CERT_ARN
config.backend_domain_name = "<< REPLACE ME >>"
config.frontend_base_url = config.backend_domain_name
config.app_service_key = "<< REPLACE ME >>"
config.elb_certificate_arn = CERT_ARN

config.static_base_url = "<< REPLACE ME >>"

config.container_port = 8081  # port number from Dockerfile

DeploymentStage(app, "DeploymentStage", config)

app.synth()
