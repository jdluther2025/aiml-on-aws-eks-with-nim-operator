from aws_cdk import (
    Stack,
    CfnOutput,
    RemovalPolicy,
    Tags,
    aws_ec2 as ec2,
    aws_efs as efs,
    aws_opensearchserverless as aoss,
)
import json
from constructs import Construct

CLUSTER_NAME = "eks-nim-platform"
AOSS_COLLECTION_NAME = "nim-rag-store"


class EksNimStack(Stack):

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # ── VPC ────────────────────────────────────────────────────────────────
        # 2 AZs, 1 NAT gateway (lab cost optimization).
        # Private subnets: EKS nodes and NIM pods.
        # Public subnets: load balancers.

        vpc = ec2.Vpc(self, "EksNimVpc",
            max_azs=2,
            nat_gateways=1,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                    cidr_mask=24,
                ),
                ec2.SubnetConfiguration(
                    name="Private",
                    subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS,
                    cidr_mask=24,
                ),
            ],
        )

        for subnet in vpc.public_subnets:
            Tags.of(subnet).add(f"kubernetes.io/cluster/{CLUSTER_NAME}", "shared")
            Tags.of(subnet).add("kubernetes.io/role/elb", "1")

        for subnet in vpc.private_subnets:
            Tags.of(subnet).add(f"kubernetes.io/cluster/{CLUSTER_NAME}", "shared")
            Tags.of(subnet).add("kubernetes.io/role/internal-elb", "1")

        # ── EFS — ReadWriteMany storage for NIMCache model weights ─────────────
        # NIMCache pre-downloads model weights to EFS so NIMService pods start
        # in ~5 min instead of ~15 min. EBS cannot be used because NIMCache
        # requires ReadWriteMany — EBS is ReadWriteOnce only.

        efs_sg = ec2.SecurityGroup(self, "EfsSg",
            vpc=vpc,
            description="NFS from EKS nodes to EFS (NIMCache storage)",
        )
        efs_sg.add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(2049),
            description="NFS from VPC",
        )

        efs_fs = efs.FileSystem(self, "NimEfs",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS,
            ),
            security_group=efs_sg,
            encrypted=True,
            performance_mode=efs.PerformanceMode.GENERAL_PURPOSE,
            throughput_mode=efs.ThroughputMode.ELASTIC,
            removal_policy=RemovalPolicy.DESTROY,
        )

        # ── OpenSearch Serverless — vector store for RAG ───────────────────────
        # VPC endpoint enables private connectivity: EKS pods → OpenSearch
        # without traffic leaving the VPC. PrivateLink — no internet exposure.
        #
        # Policy sequence (AOSS requires all three before collection is usable):
        #   1. Encryption policy  — KMS config
        #   2. Network policy     — VPC-only access via the VPC endpoint
        #   3. Collection         — depends on both policies existing
        #   4. Data access policy — created in create-cluster.sh after eksctl
        #                           creates the chatbot IAM role

        aoss_sg = ec2.SecurityGroup(self, "AossSg",
            vpc=vpc,
            description="HTTPS from EKS pods to OpenSearch Serverless VPC endpoint",
        )
        aoss_sg.add_ingress_rule(
            peer=ec2.Peer.ipv4(vpc.vpc_cidr_block),
            connection=ec2.Port.tcp(443),
            description="HTTPS from VPC",
        )

        aoss_vpce = aoss.CfnVpcEndpoint(self, "AossVpcEndpoint",
            name="nim-rag-vpce",
            vpc_id=vpc.vpc_id,
            subnet_ids=[s.subnet_id for s in vpc.private_subnets],
            security_group_ids=[aoss_sg.security_group_id],
        )

        encryption_policy = aoss.CfnSecurityPolicy(self, "AossEncryptionPolicy",
            name="nim-rag-encryption",
            type="encryption",
            policy=json.dumps({
                "Rules": [{
                    "ResourceType": "collection",
                    "Resource": [f"collection/{AOSS_COLLECTION_NAME}"],
                }],
                "AWSOwnedKey": True,
            }),
        )

        network_policy = aoss.CfnSecurityPolicy(self, "AossNetworkPolicy",
            name="nim-rag-network",
            type="network",
            policy=json.dumps({
                "Rules": [
                    {
                        "ResourceType": "collection",
                        "Resource": [f"collection/{AOSS_COLLECTION_NAME}"],
                    },
                    {
                        "ResourceType": "dashboard",
                        "Resource": [f"collection/{AOSS_COLLECTION_NAME}"],
                    },
                ],
                "AllowFromPublic": False,
                "SourceVPCEs": [aoss_vpce.ref],
            }),
        )

        collection = aoss.CfnCollection(self, "AossCollection",
            name=AOSS_COLLECTION_NAME,
            type="VECTORSEARCH",
        )
        collection.add_dependency(encryption_policy)
        collection.add_dependency(network_policy)

        # ── Outputs ─────────────────────────────────────────────────────────────
        # scripts/create-cluster.sh reads these via CloudFormation describe-stacks.

        CfnOutput(self, "VpcId",
            value=vpc.vpc_id,
            description="VPC ID for eksctl cluster config",
        )
        CfnOutput(self, "PrivateSubnetIds",
            value=",".join([s.subnet_id for s in vpc.private_subnets]),
            description="Private subnet IDs (comma-separated)",
        )
        CfnOutput(self, "PublicSubnetIds",
            value=",".join([s.subnet_id for s in vpc.public_subnets]),
            description="Public subnet IDs for load balancers (comma-separated)",
        )
        CfnOutput(self, "ClusterName",
            value=CLUSTER_NAME,
            description="EKS cluster name",
        )
        CfnOutput(self, "EfsFileSystemId",
            value=efs_fs.file_system_id,
            description="EFS file system ID for NIMCache StorageClass",
        )
        CfnOutput(self, "AossCollectionEndpoint",
            value=collection.attr_collection_endpoint,
            description="OpenSearch Serverless collection endpoint for chatbot",
        )
        CfnOutput(self, "AossCollectionArn",
            value=collection.attr_arn,
            description="OpenSearch Serverless collection ARN",
        )
        CfnOutput(self, "AossCollectionId",
            value=collection.ref,
            description="OpenSearch Serverless collection ID (for destroy script)",
        )
