// AWS infrastructure for the experiments (Pulumi, JavaScript).
// Based on the Poridhi lab: 1 VPC, 1 public subnet, 1 Nginx instance, 1 K3s master, 2 K3s workers.
// Changes from the lab: private IPs are exported too (Nginx and the workers talk over the VPC),
// and the security group is tightened to what the experiments actually use.
const pulumi = require("@pulumi/pulumi");
const aws = require("@pulumi/aws");

const config = new pulumi.Config();
// Your own public IP, e.g. "203.0.113.7/32". Default is open to the world (lab style).
const adminCidr = config.get("adminCidr") || "0.0.0.0/0";

const vpc = new aws.ec2.Vpc("my-vpc", {
    cidrBlock: "10.0.0.0/16",
    enableDnsHostnames: true,
    tags: { Name: "my-vpc" },
});

const publicSubnet = new aws.ec2.Subnet("public-subnet", {
    vpcId: vpc.id,
    cidrBlock: "10.0.1.0/24",
    availabilityZone: "ap-southeast-1a",
    mapPublicIpOnLaunch: true,
    tags: { Name: "public-subnet" },
});

const igw = new aws.ec2.InternetGateway("internet-gateway", {
    vpcId: vpc.id,
    tags: { Name: "igw" },
});

const publicRouteTable = new aws.ec2.RouteTable("public-route-table", {
    vpcId: vpc.id,
    routes: [{ cidrBlock: "0.0.0.0/0", gatewayId: igw.id }],
    tags: { Name: "rt-public" },
});

new aws.ec2.RouteTableAssociation("public-route-table-association", {
    subnetId: publicSubnet.id,
    routeTableId: publicRouteTable.id,
});

// Inbound: SSH and HTTP from you, everything inside the VPC (K3s API 6443, flannel VXLAN 8472,
// kubelet 10250, NodePort 30001). Outbound: everything (apt, Docker Hub, get.k3s.io).
const sg = new aws.ec2.SecurityGroup("cluster-secgrp", {
    vpcId: vpc.id,
    description: "SSH/HTTP from admin, all traffic inside the VPC",
    ingress: [
        { protocol: "tcp", fromPort: 22, toPort: 22, cidrBlocks: [adminCidr], description: "SSH" },
        { protocol: "tcp", fromPort: 80, toPort: 80, cidrBlocks: [adminCidr], description: "HTTP to Nginx" },
        { protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["10.0.0.0/16"], description: "inside VPC" },
    ],
    egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
});

// Ubuntu 24.04 LTS in ap-southeast-1 (same AMI as the lab)
const amiId = "ami-060e277c0d4cce553";

function instance(name, type, keyName, tag) {
    return new aws.ec2.Instance(name, {
        instanceType: type,
        vpcSecurityGroupIds: [sg.id],
        ami: amiId,
        subnetId: publicSubnet.id,
        keyName: keyName,
        associatePublicIpAddress: true,
        tags: { Name: tag },
    });
}

const nginx = instance("nginx-instance", "t2.micro", "nginx", "nginx-lb");
const master = instance("master-instance", "t3.small", "k3sCluster", "master");
const worker1 = instance("worker1-instance", "t3.small", "k3sCluster", "worker1");
const worker2 = instance("worker2-instance", "t3.small", "k3sCluster", "worker2");

exports.vpcId = vpc.id;
exports.nginxPublicIp = nginx.publicIp;
exports.masterPublicIp = master.publicIp;
exports.masterPrivateIp = master.privateIp;
exports.worker1PublicIp = worker1.publicIp;
exports.worker1PrivateIp = worker1.privateIp;
exports.worker1InstanceId = worker1.id;
exports.worker2PublicIp = worker2.publicIp;
exports.worker2PrivateIp = worker2.privateIp;
exports.worker2InstanceId = worker2.id;
