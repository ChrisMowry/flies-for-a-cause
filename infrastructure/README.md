# Infrastructure

All AWS resources for **Flies for a Cause** are defined as CloudFormation templates in `cloudformation/` and deployed via the scripts in `scripts/`. There is no manual ("click-ops") resource creation — every resource must be defined here.

## Environments

Every template accepts an `Environment` parameter with allowed values `dev` and `prod`, **except `dns-zone.yaml`**. A Route53 hosted zone covers the apex domain and all of its subdomains (production and development alike), so it is a single global stack deployed once, ever, per AWS account — not per environment. Every other stack is a fully separate, independently deployable set of resources per environment — nothing else is shared between dev and prod.

## Conventions

- **Stack naming:** `flies-for-a-cause-<environment>-<template-name>` (e.g., `flies-for-a-cause-dev-base`).
- **Resource naming:** resource names/paths are prefixed or namespaced with `flies-for-a-cause-<environment>-...` (or, for hierarchical resources like SSM parameters, `/flies-for-a-cause/<environment>/...`) so dev and prod resources never collide.
- **Tags:** every resource is tagged with `Project=FliesForACause`, `Environment=<environment>`, and `ManagedBy=CloudFormation`.
- **Cross-stack values:** shared values (domain names, log group names, etc.) are exported using the `flies-for-a-cause-<environment>-<OutputName>` convention so other stacks can import them with `Fn::ImportValue` instead of duplicating values.

## Templates

| Template | Purpose |
| --- | --- |
| `base.yaml` | Foundational per-environment stack: shared SSM configuration parameters and the shared application log group. Deploy this first for a new environment. |
| `dns-zone.yaml` | The single, global Route53 hosted zone for `flies-for-a-cause.org`. Deployed once, ever (not per environment) — see [Environments](#environments). Deploy before `certificates.yaml` or `dns-records.yaml`. |
| `certificates.yaml` | Per-environment ACM certificates for the website and API custom domains, DNS-validated automatically against the shared hosted zone. **Must be deployed in `us-east-1`** regardless of the project's overall region, because CloudFront only accepts certificates from that region. |
| `hosting.yaml` | Static website hosting: a private S3 bucket (holding the built UI) behind a CloudFront distribution using Origin Access Control, so the bucket is never reachable directly. Aliased to its custom domain using the certificate from `certificates.yaml`. |
| `dns-records.yaml` | Per-environment Route53 alias records pointing the website domain (`flies-for-a-cause.org` / `dev.flies-for-a-cause.org`) at its CloudFront distribution. The API domain records (`api.` / `dev-api.`) are added alongside Story 1.6 (API Gateway), once that custom domain resource exists. |
| `cognito.yaml` | Per-environment Cognito user pool + app client for admin authentication (up to 5 administrators), used by the Admin Page login and the API Gateway JWT authorizer (Story 1.6). Pool/client IDs are exposed via SSM parameters for the UI build. Independent of the DNS/certificate/hosting chain — only depends on `base.yaml`. |

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

`dns-zone.yaml` is the one exception: since it's not per-environment, it doesn't fit `deploy-stack.sh`'s `<env> <template-name>` convention and is deployed directly instead:

```bash
# Deploy once, ever, per AWS account
aws cloudformation deploy \
  --stack-name flies-for-a-cause-dns-zone \
  --template-file cloudformation/dns-zone.yaml \
  --tags Project=FliesForACause ManagedBy=CloudFormation
```

### Deployment order for a new environment

Later templates import values (domain names, certificate ARNs, the hosted zone ID) exported by earlier ones, so they must be deployed in this order the first time an environment is stood up:

1. `dns-zone.yaml` (only if not already deployed — it's global, see above)
2. `base.yaml <env>`
3. `certificates.yaml <env>` — **in `us-east-1`**
4. `hosting.yaml <env>` (or its update, once a certificate exists)
5. `dns-records.yaml <env>`

`cognito.yaml <env>` only depends on `base.yaml` and can be deployed at any point after it, independent of the dns-zone/certificates/hosting/dns-records chain above.

Tearing an environment down happens in the reverse order (`dns-records.yaml` first, `base.yaml` last), so nothing is deleted out from under a stack that still imports its exports. `cognito.yaml` can be deleted at any point in that sequence, same as it can be deployed at any point.

## Verifying the website hosting stack

After deploying `hosting.yaml`, confirm the S3 bucket and CloudFront distribution are correctly wired together by uploading a test page and requesting it through CloudFront (not directly from S3 — direct S3 access should be blocked):

```bash
# Deploy the hosting stack for dev
./scripts/deploy-stack.sh dev hosting

# Look up the bucket name and CloudFront domain name from the stack outputs
BUCKET=$(aws cloudformation describe-stacks --stack-name flies-for-a-cause-dev-hosting \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteBucketName'].OutputValue" --output text)
DISTRIBUTION_DOMAIN=$(aws cloudformation describe-stacks --stack-name flies-for-a-cause-dev-hosting \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteDistributionDomainName'].OutputValue" --output text)

# Upload the test page
aws s3 cp test-site/index.html "s3://${BUCKET}/index.html"

# Request it through CloudFront (allow a few minutes for the distribution to deploy)
curl -I "https://${DISTRIBUTION_DOMAIN}/"
```

A successful check returns `HTTP/2 200` from the CloudFront domain. Requesting the same object directly from the bucket's URL should be denied (`403 Forbidden`), confirming the bucket isn't publicly reachable outside of CloudFront.

## Verifying domains and certificates

Once `dns-zone.yaml`, `certificates.yaml`, and the domain-aliased `hosting.yaml` are deployed for an environment (see deployment order above):

```bash
# Confirm both certificates issued (DNS validation can take several minutes)
aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?contains(DomainName, 'flies-for-a-cause.org')]"

# Deploy the website's Route53 alias record
./scripts/deploy-stack.sh dev dns-records

# Confirm the custom domain resolves and serves over HTTPS
curl -I "https://dev.flies-for-a-cause.org/"
```

A successful check returns `HTTP/2 200` from the custom domain directly (no `*.cloudfront.net` in the URL), confirming the hosted zone, certificate, and CloudFront alias are all wired together correctly. The `api.` / `dev-api.` records aren't part of this check yet — see the scope note in `dns-records.yaml` and Story 1.6.

## Verifying the Cognito user pool

After deploying `cognito.yaml`, confirm an admin can actually be created and authenticated (Story 1.5's acceptance criterion) using the helper script, which creates/resets a test user, sets a permanent password, and authenticates:

```bash
./scripts/create-test-admin-user.sh dev test-admin@example.com 'Tempp@ssw0rd123!'
```

A successful run prints an `AuthenticationResult` containing an `IdToken`, `AccessToken`, and `RefreshToken` — the `IdToken` is the JWT the Admin Page would send to the secured API routes. This script is for test/dev verification only (the password is passed as a plain CLI argument); don't reuse a real credential with it.

## Prerequisites

- AWS CLI v2, configured with credentials that have permission to manage the resources in these templates.
- An AWS account/region to deploy into. CloudFront requires any associated ACM certificates to be requested in `us-east-1`, so `us-east-1` is the recommended default region for this project.
