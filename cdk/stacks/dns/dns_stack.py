from aws_cdk import (
    core,
    aws_route53 as route53,
)


class DnsStack(core.Stack):
    def __init__(
        self,
        scope: core.Construct,
        construct_id: str,
        domain_name: str,  # example.com
        **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.hosted_zone = route53.HostedZone.from_lookup(
            self,
            "HostedZone",
            domain_name=domain_name
        )
