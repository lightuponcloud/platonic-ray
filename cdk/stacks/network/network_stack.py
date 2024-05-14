from aws_cdk import (
    core,
    aws_ec2 as ec2,
)


class NetworkStack(core.Stack):
    vpc: ec2.IVpc
    es_sg_id: str

    def __init__(self, scope: core.Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.vpc = ec2.Vpc(
            self,
            "VPC",
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    cidr_mask=24,
                    subnet_type=ec2.SubnetType.PUBLIC,
                ),
                ec2.SubnetConfiguration(
                    name="Private",
                    cidr_mask=24,
                    subnet_type=ec2.SubnetType.PRIVATE,
                )
            ],
            nat_gateway_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            nat_gateways=1,
            enable_dns_hostnames=True,
            enable_dns_support=True,
            cidr="10.0.0.0/16",
            max_azs=3,
        )
