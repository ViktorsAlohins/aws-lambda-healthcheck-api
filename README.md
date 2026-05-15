# AWS Serverless Health Check API

A serverless HTTP API that logs incoming requests and stores them in a database.
The infrastructure is fully managed with Terraform, and deployments to both staging
and production are automated through a GitHub Actions pipeline.

## Architecture

```
API Gateway (HTTP)
      │
      ▼
Lambda Function (Python 3.12)
      │
      ├── CloudWatch Logs (structured event logging)
      └── DynamoDB Table (request storage, KMS encrypted)
```

**AWS resources created per environment**

| Resource | Staging | Production |
|---|---|---|
| API Gateway | staging-health-check-api | prod-health-check-api |
| Lambda | staging-health-check-lambda | prod-health-check-lambda |
| DynamoDB | staging-requests-db | prod-requests-db |
| KMS key | alias/staging-requests-db-key | alias/prod-requests-db-key |

## Prerequisites

### 1. Apply the bootstrap configuration

The bootstrap directory contains one-time account-level setup. Run it locally
before using the CI/CD pipeline for the first time.

```bash
cd bootstrap
terraform init
terraform apply \
  -var="github_owner=YOUR_GITHUB_USERNAME" \
  -var="github_repo=REPO_NAME"
```

Save the output values. You will need `tfstate_bucket` and both role ARNs in the next steps.

### 2. Create GitHub Environments

Go to your repository Settings and open the Environments section. Create two environments:

- `staging`
- `prod` (add yourself as a required reviewer to enable manual approval before prod deployments)

### 3. Add environment variables

Add the following variable inside each GitHub Environment.

**staging environment**

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | `staging_deploy_role_arn` from bootstrap output |

**prod environment**

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | `prod_deploy_role_arn` from bootstrap output |

### 4. Add repository variables

Go to Settings > Secrets and variables > Actions > Variables tab and add the following.

| Variable | Value |
|---|---|
| `TF_STATE_BUCKET` | `tfstate_bucket` from bootstrap output |

## How the CI/CD pipeline works

The pipeline is triggered manually via the GitHub Actions UI. When you start a run,
you select the target environment (staging or prod).

For `prod` deployments, GitHub pauses the workflow and shows an approval button.
A designated reviewer must approve the run before any AWS changes are made.

Once approved (or immediately for staging), the pipeline runs these steps in order:

1. **Dependency scan** using `pip-audit` to check for known vulnerabilities in Python packages
2. **IaC scan** using `tfsec` to check the Terraform code for security misconfigurations
3. **Package Lambda** by zipping `handler.py`
4. **Terraform init** connecting to the S3 remote backend for the selected environment
5. **Terraform fmt** to verify code formatting
6. **Terraform validate** to check configuration syntax
7. **Terraform plan** to preview the changes
8. **Terraform apply** to deploy the infrastructure

## Deploying to staging

1. Open the Actions tab in your GitHub repository
2. Select the **deploy** workflow in the left sidebar
3. Click **Run workflow**
4. Choose `staging` from the environment dropdown
5. Click **Run workflow**

The pipeline output includes `health_url` at the end of the apply step.

## Testing the endpoint

Replace `YOUR_API_URL` with the `health_url` value from the Terraform output.

**GET request**

```bash
curl https://YOUR_API_URL/health
```

**POST request**

```bash
curl -X POST https://YOUR_API_URL/health \
  -H "Content-Type: application/json" \
  -d '{"payload": "hello"}'
```

**Expected response**

```json
{
  "status": "healthy",
  "message": "Request processed and saved."
}
```

If the POST body is missing the `payload` key, the function returns a 400 error.

## Design choices

### OIDC authentication instead of static AWS keys

The task requires a dedicated IAM role for deployment but does not specify how
the pipeline authenticates to AWS. The common approach is to create an IAM user,
generate access keys, and store them as GitHub secrets. The problem is that
those keys are long-lived and need to be rotated manually.

Instead, the pipeline uses OpenID Connect. GitHub generates a short-lived token
for each workflow run, and AWS exchanges it for temporary credentials through
STS. There are no secrets to store or rotate, and the trust policy is scoped to
a specific GitHub Environment, so only a job running in `staging` can assume
the staging role.

### Bootstrap pattern and S3 remote backend

The task does not mention how to manage Terraform state. By default, Terraform
stores state locally, which creates a serious problem in CI/CD. Every pipeline
run starts with an empty state file, so Terraform tries to create all resources
from scratch. If a run fails halfway through, the resources that were already
created become orphaned, and the next run fails because those same resources
already exist in AWS.

The solution is to store state in an S3 bucket. But this creates a
chicken-and-egg situation where the bucket needs to exist before Terraform can
run, yet Terraform is what creates infrastructure.

A separate `bootstrap` directory handles this. It has its own Terraform
configuration that is applied once locally. Bootstrap creates the S3 state
bucket, the GitHub OIDC provider, and the deployment IAM roles. The main
application configuration then uses that bucket as its remote backend, with a
separate state key per environment.

State locking uses the native S3 mechanism introduced in Terraform 1.10, which
stores a `.tflock` file alongside the state object instead of relying on a
separate DynamoDB table.

### DynamoDB Point-in-Time Recovery

PITR is enabled on both tables. The task does not require this, but it adds a
meaningful safety net at no extra cost. If data gets corrupted or accidentally
deleted, the table can be restored to any point within the last 35 days.
