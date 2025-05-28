<h1 align=center>TAK Server Infra</h1>

<p align=center>CloudFormation managed infrastructure for TAK Server on Docker containers</p>

## Background

The [Team Awareness Kit (TAK)](https://tak.gov/solutions/emergency) provides Fire, Emergency Management, and First Responders an operationally agnostic tool for improved situational awareness and a common operational picture. 
This repo deploys the base infrastructure required to deploy a [TAK server](https://tak.gov/solutions/emergency) along with [Authentik](https://goauthentik.io/) as the authentication layer on AWS.

## Pre-Reqs

> [!IMPORTANT]
> The Auth-Infra service assumes some pre-requisite dependencies are deployed before
> initial deployment.

The following dependencies must be fulfilled:
- An [AWS Account](https://signin.aws.amazon.com/signup?request_type=register).
- A Domain Name under which the TAK server is made available, e.g. `tak.nz` in the example here.
- An [AWS ACM certificate](https://docs.aws.amazon.com/acm/latest/userguide/gs.html) certificate.
  - This certificate should cover the main domain - e.g. `tak.nz`, as well as two levels of wildcard subdomains, e.g. `*.tak.nz` and `*.*.tak.nz`.

The following stack layers need to be created before deploying this layer:

| Name                  | Notes |
| --------------------- | ----- |
| `coe-base-<name>`      | VPC, ECS cluster, and ECR repository - [repo](https://github.com/TAK-NZ/base-infra)      |
| `coe-auth-<name>`     | Authentication layer using Authentik - [repo](https://github.com/TAK-NZ/auth-infra)      |



## AWS Deployment

### 1. Install Tooling Dependencies

From the root directory, install the deploy dependencies

```sh
npm install
```

### 2.(Optional) TAK Server configuration

The `coe-base-<name>` layer creates an S3 bucket with the name `coe-auth-config-s3-<name>-<region>-env-config` which can be used for TAK Server configuration via an .env configuration file.
An example configuration file with the name [takserver-config.env.example] is provided in this repo. Adjust this file based on your needs and store it in the created S3 bucket as `takserver-config.env`.

### 3. Building Docker Images & Pushing to ECR

An script to build docker images and publish them to your ECR is provided and can be run using:

```
npm run build -- --env devtest
```

from the root of the project. The script supports additional parameters for deploying the docker container into ECR into a specific region or using a specific AWS account profile.

### 4. CloudFormation Stack Deployment
Deployment to AWS is handled via AWS Cloudformation. The templates can be found in the `./cloudformation`
directory. The deployment itself is performed by [Deploy](https://github.com/openaddresses/deploy) which
was installed in the previous step.

#### Sub-Stack Deployment

The CloudFormation is split into two stacks to ensure consistent deploy results.

The first portion deploys the ELB, database and all necessary related filestore
components. The second portion deploys the ECS Service itself.

It is important that this layer is deployed into an existing `base-infra` stack.

**Step 1:** Create Network Portion:

```
npx deploy create <stack> --template ./cloudformation/network.template.js
```

**Step 2:** Setup a DNS CNAME from your desired hostname for the TAK server to the ELB hostname. The ELB hostname is one of the CloudFormation template outputs. An example would be `ops.tak.nz` as the hostname for the TAK server.

**Step3:** Create Service Portion (Once DNS been set & propagated)

```
npx deploy create <stack>
```

## About the deploy tool

The deploy tool can be run via the `npx deploy` command.

To install it globally - view the deploy [README](https://github.com/openaddresses/deploy)

Deploy uses your existing AWS credentials. Ensure that your `~/.aws/credentials` has an entry like:
 
```
[coe]
aws_access_key_id = <redacted>
aws_secret_access_key = <redacted>
```

Stacks can be created, deleted, cancelled, etc all via the deploy tool. For further information
information about `deploy` functionality run the following for help.
 
```sh
npx deploy
```
 
Further help about a specific command can be obtained via something like:

```sh
npx deploy info --help
```

## Estimated Cost

The estimated AWS cost for this layer of the stack without data transfer or data processing based usage is:

| Environment type      | Estimated monthly cost | Estimated yearly cost |
| --------------------- | ----- | ----- |
| Prod                  | 366.87 USD | 4,402.44 USD |
| Dev-Test              | 106.25 USD | 1,275.00 USD |
