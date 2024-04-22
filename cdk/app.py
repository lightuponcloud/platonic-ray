#!/usr/bin/env python3
import os

from aws_cdk import (
    core,
    aws_ec2 as ec2,
)

from config import (
    Config,
    DatabaseConfig,
    AppFargateStackConfig,
    WorkerFargateStackConfig,
    SchedulerFargateStackConfig,
    NotificationServiceFargateStackConfig,
    ApiGatewayConfig,
    ContainerEnv,
)

app = core.App()
CDK_DEFAULT_ACCOUNT = "107892035587"
CDK_DEFAULT_REGION = "us-east-2"

app.synth()
