from dataclasses import dataclass


@dataclass
class ContainerEnv:
    """
    Container environment variables
    """

    flask_env: str = "development"
    gunicorn_num_workers: str = "1"
    frontend_base_url: str = None


@dataclass
class FargateStackConfig:
    task_cpu: int = 256
    task_memory_limit_mib: int = None

    # container env
    container_env: ContainerEnv = ContainerEnv


@dataclass
class NotificationServiceFargateStackConfig(FargateStackConfig):
    elb_certificate_arn: str = None
