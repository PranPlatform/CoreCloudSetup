# CoreCloudSetup

Infrastructure-as-code for the one-time foundational setup of an AWS account.

A fresh AWS account only has a root user and nothing else. This repo puts in place the basics needed before the account is used for real work: a safe, non-root way to deploy things, and a network for applications to run in. The account owner runs it once as root, and from then on day-to-day work happens with limited, short-lived credentials instead of root.

## What it sets up

- **Deployer access:** an IAM user and role that can deploy almost anything, but with guardrails that stop them from undoing the foundation, escalating their own privileges, or touching account-level settings. The user's only job is to get temporary credentials for the role.
- **Network:** a VPC split into three tiers (public, private and data), each spread across two availability zones, so internet-facing, application and database resources stay separated.

## Layout

```
config/       Settings for the account (region, names, network ranges, tags)
templates/    CloudFormation templates, one concern per stack
  iam/        Guardrails, deployer user, deployer role
  network/    VPC, subnet tiers, NAT, endpoints
scripts/      Deploy, tear down, and assume the deployer role
Makefile      Shortcuts for linting, validating and deploying
```

The templates are deliberately small and independent. Stacks share values through SSM Parameter Store rather than depending on each other directly, so each piece can be changed or replaced on its own.

## Usage

1. Edit `config/account.json` for your account.
2. Sign in to the AWS console as root, open **CloudShell**, clone this repo and run:

   ```bash
   make deploy
   ```

3. In the console, create an access key for the deployer user and add it to your local AWS CLI as a profile.
4. From then on, get temporary deployer credentials with:

   ```bash
   eval "$(scripts/assume-deployer.sh config/account.json)"
   ```

Other commands:

| Command | What it does |
|---|---|
| `make lint` | Check templates and scripts for errors |
| `make validate` | Validate templates against the CloudFormation API |
| `make deploy STACKS="network-nat"` | Deploy only the listed stacks |
| `make teardown` | Delete everything (root only, asks for confirmation) |

## Notes

- The foundation is managed by root only. The deployer role is intentionally unable to change these stacks.
- This is an experimental, single-account setup. Some resources cost money while they exist, so tear down what you aren't using.
