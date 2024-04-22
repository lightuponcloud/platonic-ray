from aws_cdk import (
    core,
    aws_elasticache as elc,
    aws_ec2 as ec2,
)
from constructs import Construct


class RedisStack(core.Stack):
    def __init__(
        self, scope: Construct, construct_id: str, vpc: ec2.Vpc, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.vpc = vpc

        self.security_group = ec2.SecurityGroup(
            self,
            "SecurityGroup",
            vpc=vpc,
        )
        self.security_group.add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(6379),
            description="ECS to redis",
        )
        self.subnet_group = elc.CfnSubnetGroup(
            self,
            "SubnetGroup",
            subnet_ids=[subnet.subnet_id for subnet in self.vpc.private_subnets],
            description="Subnet",
        )
        self.redis = elc.CfnCacheCluster(
            self,
            "RedisCluster",
            engine="redis",
            cache_node_type="cache.t3.micro",
            num_cache_nodes=1,
            cache_subnet_group_name=self.subnet_group.ref,
            vpc_security_group_ids=[self.security_group.security_group_id],
        )
