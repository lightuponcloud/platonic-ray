import json

from aws_cdk import (
    core,
    aws_apigatewayv2 as apigateway,
    aws_certificatemanager as cert,
    aws_logs as logs,
)

from config.common import Config


class RestApiStack(core.Stack):
    def __init__(
        self, scope: core.Construct, construct_id: str, config: Config, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.api_certificate = cert.Certificate.from_certificate_arn(
            self,
            "ApiDomainCertificate",
            certificate_arn=config.api_certificate_arn,
        )

        self.api_domain = apigateway.DomainName(
            self,
            "CustomApiDomainName",
            domain_name=config.backend_domain_name,
            certificate=self.api_certificate,
        )

        self.api = apigateway.HttpApi(
            self,
            "RestApi",
            api_name="Primary dataroom services",
            description="Api Gateway for Auth & Data services",
            default_domain_mapping=apigateway.DomainMappingOptions(
                domain_name=self.api_domain
            ),
            cors_preflight=apigateway.CorsPreflightOptions(
                allow_credentials=True,
                allow_headers=[
                    "Content-Type",
                    "X-Amz-Date",
                    "Authorization",
                    "X-Api-Key",
                    "Cookies",
                    "User-Agent",
                ],
                allow_methods=[apigateway.CorsHttpMethod.ANY],
                allow_origins=[
                    config.frontend_base_url,
                    # Local origins
                    "http://localhost:8080",
                    "http://0.0.0.0:8080",
                    "http://127.0.0.1:8080",
                ],
            ),
        )

        # Enable logging with the retention of 90 days
        stage: apigateway.CfnStage = self.api.default_stage.node.default_child
        log_group = logs.LogGroup(
            self,
            "ApiGatewayAccessLogs",
            retention=logs.RetentionDays.THREE_MONTHS,
            log_group_name=f"/aws/{config.stage_prefix}/apigateway",
        )
        stage.access_log_settings = apigateway.CfnStage.AccessLogSettingsProperty(
            destination_arn=log_group.log_group_arn,
            format=json.dumps(
                {
                    "requestId": "$context.requestId",
                    "userAgent": "$context.identity.userAgent",
                    "sourceIp": "$context.identity.sourceIp",
                    "requestTime": "$context.requestTime",
                    "httpMethod": "$context.httpMethod",
                    "path": "$context.path",
                    "status": "$context.status",
                    "responseLength": "$context.responseLength",
                }
            ),
        )
