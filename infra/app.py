#!/usr/bin/env python3
import os
import aws_cdk as cdk
from eks_nim.eks_nim_stack import EksNimStack

app = cdk.App()

EksNimStack(app, "EksNimStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"),
        region=os.getenv("CDK_DEFAULT_REGION"),
    ),
)

app.synth()
