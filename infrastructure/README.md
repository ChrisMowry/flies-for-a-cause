# Infrastructure

All AWS resources for **Flies for a Cause** are defined as CloudFormation templates in `cloudformation/` and deployed via the scripts in `scripts/`. There is no manual ("click-ops") resource creation — every resource must be defined here.

## Environments

Every template accepts an `Environment` parameter with allowed values `dev` and `prod`, **except `dns-zone.yaml` and `github-oidc.yaml`**. A Route53 hosted zone covers the apex domain and all of its subdomains (production and development alike), and an AWS account can only have one OIDC provider per issuer URL, so both are single global stacks deployed once, ever, per AWS account — not per environment. Every other stack is a fully separate, independently deployable set of resources per environment — nothing else is shared between dev and prod.

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
| `cognito.yaml` | Per-environment Cognito user pool + app client for admin authentication (up to 5 administrators), used by the Admin Page login and the API Gateway JWT authorizer. Pool/client IDs are exposed via SSM parameters for the UI build. Independent of the DNS/certificate/hosting chain — only depends on `base.yaml`. |
| `api-gateway.yaml` | Per-environment HTTP API Gateway: the stable HTTPS endpoint the UI calls, a Cognito JWT authorizer ready for secured routes, and a placeholder Lambda + two test routes (`GET /health` public, `GET /health/secure` JWT-protected) proving the whole chain works. Epic 3 adds the real Lambda/routes to this same API. |
| `dns-records.yaml` | Per-environment Route53 alias records pointing the website domain (`flies-for-a-cause.org` / `dev.flies-for-a-cause.org`) at its CloudFront distribution, and the API domain (`api.` / `dev-api.`) at its API Gateway custom domain. |
| `social-media-queue.yaml` | Per-environment `social-media-post-queue.fifo` SQS queue (+ dead-letter queue) connecting the Social Media Scraper Lambda (Epic 7) to the Social Media Post Processor Lambda (Epic 8), plus two standalone IAM managed policies scoping send vs. receive/delete access for those Lambdas' future execution roles. Has no dependencies on any other template — deployable independently, any time. |
| `scraper-schedule.yaml` | Per-environment EventBridge rule firing every 5 minutes for the Social Media Scraper Lambda (Epic 7), plus a placeholder Lambda target proving the invoke wiring works. `ScheduleState` (`ENABLED`/`DISABLED`, default `DISABLED`) can be overridden independently per environment. Has no dependencies on any other template. |
| `notifications.yaml` | Per-environment SNS topic the administrator subscribes to (email required, SMS optional) for scam alerts (Epic 8) and future scraper health alarms (Epic 7), plus a standalone IAM managed policy scoping publish access for those Lambdas' future execution roles. Requires the `AdminEmail` parameter. Has no dependencies on any other template. |
| `github-oidc.yaml` | The single, global GitHub Actions OIDC identity provider. Deployed once, ever (not per environment), like `dns-zone.yaml` — see [Environments](#environments). Only needed if the AWS account doesn't already have one (AWS allows just one per account, so an account already used by another project for GitHub Actions may already have it - `deploy-role.yaml` trusts it by its well-known ARN, not a stack export, so it doesn't matter which project created it). |
| `deploy-role.yaml` | Per-environment IAM role the GitHub Actions CI/CD pipeline assumes via OIDC to deploy that environment — scoped so the `dev` role only trusts workflow runs under the `dev` GitHub Environment, and `prod` only trusts runs under `prod` (each Environment is itself restricted to its matching branch). See [CI/CD Pipeline](#cicd-pipeline). |

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

Neither script passes `--region`, so they deploy to whatever region your AWS CLI/profile defaults to. The CI/CD pipeline always deploys to `us-east-1` (see [Prerequisites](#prerequisites)), and CloudFormation exports/imports (e.g. `certificates.yaml` and others importing `dns-zone.yaml`'s hosted zone ID) only resolve within the same region — so when deploying any of these stacks manually, make sure your default region is also `us-east-1` (e.g. `export AWS_REGION=us-east-1`, or `--region us-east-1` on `aws-vault exec`/`aws configure` for that profile) to avoid creating stacks CloudFormation can't cross-reference.

For templates that take more than the `Environment` parameter, append additional bare `key=value` pairs after the template name (the script already passes `--parameter-overrides` once; don't repeat that flag) — e.g. `./scripts/deploy-stack.sh dev scraper-schedule ScheduleState=ENABLED`.

`dns-zone.yaml` and `github-oidc.yaml` are the exceptions: since neither is per-environment, they don't fit `deploy-stack.sh`'s `<env> <template-name>` convention and are deployed directly instead:

```bash
# Deploy once, ever, per AWS account - in us-east-1, matching the CI/CD
# pipeline's region, so other stacks (e.g. certificates.yaml) can import
# dns-zone.yaml's exports (CloudFormation exports are region-scoped)
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name flies-for-a-cause-dns-zone \
  --template-file cloudformation/dns-zone.yaml \
  --tags Project=FliesForACause ManagedBy=CloudFormation

aws cloudformation deploy \
  --region us-east-1 \
  --stack-name flies-for-a-cause-github-oidc \
  --template-file cloudformation/github-oidc.yaml \
  --capabilities CAPABILITY_IAM \
  --tags Project=FliesForACause ManagedBy=CloudFormation
```

> **After (re)creating `dns-zone.yaml`, point the domain at the new zone's nameservers.** Every hosted zone gets its own random set of four nameservers, so if the stack is ever deleted and recreated, the domain registration (which lives outside CloudFormation) keeps delegating to the old zone. Nothing in the templates breaks — they import the new zone ID — but ACM DNS validation in `certificates.yaml` can never succeed, so that stack sits in `CREATE_IN_PROGRESS` indefinitely and the CI/CD deploy hangs until it times out. Fix it by updating the registrar:
>
> ```bash
> # The zone's current nameservers
> aws cloudformation describe-stacks --region us-east-1 --stack-name flies-for-a-cause-dns-zone \
>   --query "Stacks[0].Outputs[?OutputKey=='NameServers'].OutputValue" --output text
>
> # Set them on the registered domain (Route 53 Domains) - list all four
> aws route53domains update-domain-nameservers --region us-east-1 \
>   --domain-name flies-for-a-cause.org \
>   --nameservers Name=<ns-1> Name=<ns-2> Name=<ns-3> Name=<ns-4>
> ```
>
> To check for a mismatch, compare that list against `nslookup -type=NS flies-for-a-cause.org`.

### Deployment order for a new environment

Later templates import values (domain names, certificate ARNs, the hosted zone ID, the Cognito pool, the API Gateway custom domain) exported by earlier ones, so they must be deployed in this order the first time an environment is stood up:

1. `dns-zone.yaml` (only if not already deployed — it's global, see above)
2. `base.yaml <env>`
3. `certificates.yaml <env>` — **in `us-east-1`**
4. `cognito.yaml <env>` (only depends on `base.yaml`; deployed here so `api-gateway.yaml` can use it, but order relative to steps 3-4 doesn't matter)
5. `hosting.yaml <env>` (or its update, once a certificate exists)
6. `api-gateway.yaml <env>` (needs `certificates.yaml` and `cognito.yaml`)
7. `dns-records.yaml <env>` (needs `hosting.yaml` and `api-gateway.yaml`)

Tearing an environment down happens in the reverse order (`dns-records.yaml` first, `base.yaml` last), so nothing is deleted out from under a stack that still imports its exports.

`social-media-queue.yaml <env>`, `scraper-schedule.yaml <env>`, and `notifications.yaml <env>` have no dependencies on any other template (none of them import anything) and can each be deployed or deleted at any point, independent of everything above and of each other.

## CI/CD Pipeline

`.github/workflows/deploy-infrastructure.yml` deploys the per-environment templates automatically: a push to `develop` deploys everything to `dev`, and a push to `main` deploys to `prod`. It authenticates to AWS via GitHub's OIDC federation (short-lived, per-run credentials) rather than long-lived access keys stored as secrets, and excludes the one-time/global bootstrap stacks below (`dns-zone.yaml`, `github-oidc.yaml`, `deploy-role.yaml`) — those are deployed manually, once, since the pipeline can't deploy the very role it needs in order to run.

### One-time bootstrap (per AWS account/environment)

1. Deploy `dns-zone.yaml` directly, as shown above (once per account). Deploy `github-oidc.yaml` the same way only if the account doesn't already have a GitHub Actions OIDC provider (`aws iam list-open-id-connect-providers` - AWS allows only one per account, so a personal account already used for another project's GitHub Actions may already have one; `deploy-role.yaml` trusts it by ARN regardless of which project created it).
2. Deploy `deploy-role.yaml` for each environment: `./scripts/deploy-stack.sh dev deploy-role` and `./scripts/deploy-stack.sh prod deploy-role`.
3. In the repo's GitHub Environments (**Settings → Environments**), set two variables on **both** the `dev` and `prod` environments:
   - `AWS_DEPLOY_ROLE_ARN` — the `DeployRoleArn` output from that environment's `deploy-role.yaml` stack.
   - `ADMIN_EMAIL` — the address `notifications.yaml` should subscribe (matches what you'd otherwise pass as `AdminEmail=...`).

### Already configured in this repository

The `dev` and `prod` GitHub Environments themselves (referenced by the workflow's `environment:` key) already exist, with:

- `prod` requiring approval from a reviewer before its job runs — this is the "approval gate" for production deploys. Add or change reviewers under **Settings → Environments → prod → Required reviewers**.
- Each environment restricted to its matching branch (`dev` → `develop`, `prod` → `main`) as a second, GitHub-enforced check alongside the workflow's own `if: github.ref == ...` condition.

### Failure handling

A failed deploy doesn't leave a stack half-updated — CloudFormation automatically rolls a failed update back on its own. To make sure a failure doesn't go unnoticed, each job's last step (on failure) publishes to that environment's `notifications.yaml` SNS topic, in addition to GitHub's own default failed-workflow email.

The `deploy-dev` job has a 45-minute `timeout-minutes` so a hang fails (and notifies) instead of running for hours. The usual culprit is `certificates.yaml` waiting on DNS validation — see the nameserver note under [Deploying and deleting a stack](#deploying-and-deleting-a-stack).

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

A successful check returns `HTTP/2 200` from the custom domain directly (no `*.cloudfront.net` in the URL), confirming the hosted zone, certificate, and CloudFront alias are all wired together correctly.

## Verifying the Cognito user pool

After deploying `cognito.yaml`, confirm an admin can actually be created and authenticated (Story 1.5's acceptance criterion) using the helper script, which creates/resets a test user, sets a permanent password, and authenticates:

```bash
./scripts/create-test-admin-user.sh dev test-admin@example.com 'Tempp@ssw0rd123!'
```

A successful run prints an `AuthenticationResult` containing an `IdToken`, `AccessToken`, and `RefreshToken` — the `IdToken` is the JWT the Admin Page would send to the secured API routes. This script is for test/dev verification only (the password is passed as a plain CLI argument); don't reuse a real credential with it.

## Verifying the API Gateway

After deploying `api-gateway.yaml` (and, for the custom-domain check, `dns-records.yaml`), confirm both the public and JWT-protected placeholder routes work:

```bash
# Deploy the API Gateway stack for dev
./scripts/deploy-stack.sh dev api-gateway

# Public route — via the default *.execute-api.* endpoint
API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name flies-for-a-cause-dev-api-gateway \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiEndpoint'].OutputValue" --output text)
curl -s "${API_ENDPOINT}/health"

# JWT-protected route — should fail without a token...
curl -i "${API_ENDPOINT}/health/secure"

# ...and succeed with one from create-test-admin-user.sh
ID_TOKEN=$(./scripts/create-test-admin-user.sh dev test-admin@example.com 'Tempp@ssw0rd123!' \
  | grep -o '"IdToken": "[^"]*"' | cut -d'"' -f4)
curl -s -H "Authorization: Bearer ${ID_TOKEN}" "${API_ENDPOINT}/health/secure"

# Once dns-records.yaml is deployed, the custom domain works the same way
curl -s "https://dev-api.flies-for-a-cause.org/health"
```

`GET /health` returns `200` with no `Authorization` header. `GET /health/secure` returns `401` without a token and `200` (with `"authenticated": true` and the token's claims) with a valid one — confirming the Cognito JWT authorizer is correctly wired up and ready for Epic 3's real secured routes to use the same pattern.

## Verifying the social media post queue

After deploying `social-media-queue.yaml`, confirm messages can actually flow through the main queue and that the redrive policy points at the dead-letter queue:

```bash
# Deploy the queue stack for dev
./scripts/deploy-stack.sh dev social-media-queue

QUEUE_URL=$(aws cloudformation describe-stacks --stack-name flies-for-a-cause-dev-social-media-queue \
  --query "Stacks[0].Outputs[?OutputKey=='QueueUrl'].OutputValue" --output text)

# Send a test message and confirm the redrive policy is attached
aws sqs send-message --queue-url "${QUEUE_URL}" \
  --message-body '{"test":true}' --message-group-id test --message-deduplication-id test-1
aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names RedrivePolicy

# Receive and delete it, proving the full send/receive/delete cycle works
RECEIPT_HANDLE=$(aws sqs receive-message --queue-url "${QUEUE_URL}" --query "Messages[0].ReceiptHandle" --output text)
aws sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${RECEIPT_HANDLE}"
```

`get-queue-attributes` should show a `RedrivePolicy` pointing at the dead-letter queue's ARN with `maxReceiveCount: 5`. The scoped `ScraperQueueSendPolicyArn` / `ProcessorQueueReceivePolicyArn` outputs aren't attached to anything yet — Epic 7 and Epic 8 attach them to the scraper and processor Lambdas' execution roles, respectively, once those roles exist.

## Verifying the scraper schedule

After deploying `scraper-schedule.yaml`, confirm the rule invokes its placeholder Lambda target on schedule, and that it can be toggled independently per environment:

```bash
# Deploy the schedule for dev, enabled so it can be observed firing
./scripts/deploy-stack.sh dev scraper-schedule ScheduleState=ENABLED

# Wait a little over 5 minutes, then check for an invocation log line
aws logs tail "/aws/lambda/flies-for-a-cause-dev-scraper-stub" --since 6m

# Confirm the rule's enabled/disabled state independently of prod
aws events describe-rule --name flies-for-a-cause-dev-scraper-schedule --query State
aws events describe-rule --name flies-for-a-cause-prod-scraper-schedule --query State
```

A successful check shows a `"Scraper schedule stub invoked"` log line roughly every 5 minutes while `ScheduleState=ENABLED`, and the dev/prod rules reporting independent `State` values. Once verified, redeploy with `ScheduleState=DISABLED` (the default) to avoid unnecessary invocations until Epic 7's real scraper Lambda replaces the stub.

## Verifying admin notifications

After deploying `notifications.yaml` with your email (and, optionally, phone number), confirm the subscription and that a test alert is actually received:

```bash
# Deploy the notifications stack for dev - AdminEmail is required, AdminPhoneNumber is optional
./scripts/deploy-stack.sh dev notifications AdminEmail=you@example.com

TOPIC_ARN=$(aws cloudformation describe-stacks --stack-name flies-for-a-cause-dev-notifications \
  --query "Stacks[0].Outputs[?OutputKey=='TopicArn'].OutputValue" --output text)

# Check subscription status - PendingConfirmation until the confirmation email/SMS is accepted
aws sns list-subscriptions-by-topic --topic-arn "${TOPIC_ARN}"

# Once confirmed, publish a test alert
aws sns publish --topic-arn "${TOPIC_ARN}" \
  --subject "Flies for a Cause - Test Alert" \
  --message "This is a test of the admin notification channel."
```

SNS sends a confirmation email (and SMS, if `AdminPhoneNumber` was set) immediately after deploy — **you must open it and confirm the subscription** before any alert is actually delivered; `list-subscriptions-by-topic` shows `PendingConfirmation` until then. A successful check has the test message arriving in your inbox (and/or as a text) after confirming. The `PublishPolicyArn` output isn't attached to anything yet — Epic 8 attaches it to the Social Media Post Processor Lambda's execution role once that Lambda exists.

## Prerequisites

- AWS CLI v2, configured with credentials that have permission to manage the resources in these templates.
- An AWS account/region to deploy into. CloudFront requires any associated ACM certificates to be requested in `us-east-1`, so `us-east-1` is the recommended default region for this project.
