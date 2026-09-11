# Infrastructure

All AWS resources for **Flies for a Cause** are defined as CloudFormation templates in `cloudformation/` and deployed via the scripts in `scripts/`. There is no manual ("click-ops") resource creation — every resource must be defined here.

## Environments

Every template accepts an `Environment` parameter with allowed values `dev` and `prod`. Each environment is a fully separate, independently deployable set of stacks — nothing is shared between them.

## Conventions

- **Stack naming:** `flies-for-a-cause-<environment>-<template-name>` (e.g., `flies-for-a-cause-dev-base`).
- **Resource naming:** resource names/paths are prefixed or namespaced with `flies-for-a-cause-<environment>-...` (or, for hierarchical resources like SSM parameters, `/flies-for-a-cause/<environment>/...`) so dev and prod resources never collide.
- **Tags:** every resource is tagged with `Project=FliesForACause`, `Environment=<environment>`, and `ManagedBy=CloudFormation`.
- **Cross-stack values:** shared values (domain names, log group names, etc.) are exported using the `flies-for-a-cause-<environment>-<OutputName>` convention so other stacks can import them with `Fn::ImportValue` instead of duplicating values.

## Templates

| Template | Purpose |
| --- | --- |
| `base.yaml` | Foundational per-environment stack: shared SSM configuration parameters and the shared application log group. Deploy this first for a new environment. |

## Deploying and deleting a stack

```bash
# Deploy (or update) the base stack for dev
./scripts/deploy-stack.sh dev base

# Deploy (or update) the base stack for prod
./scripts/deploy-stack.sh prod base

# Tear a stack down completely (waits for deletion to finish)
./scripts/delete-stack.sh dev base
```

Both scripts derive the stack name from the environment and template name, so deploying and deleting a given environment's stacks is fully scripted — no manual cleanup steps in the AWS Console are required.

Additional `--parameter-overrides key=value` pairs can be appended to `deploy-stack.sh` for templates that take more than the `Environment` parameter.

## Prerequisites

- AWS CLI v2, configured with credentials that have permission to manage the resources in these templates.
- An AWS account/region to deploy into. CloudFront requires any associated ACM certificates to be requested in `us-east-1`, so `us-east-1` is the recommended default region for this project.
