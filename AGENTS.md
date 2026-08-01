# Repo 2 / 5 — `1sde-databricks-02-infra`

> Copy to repo root as `AGENTS.md`. Sections 0–8 are agent instructions. Section 9 is
> yours, by hand. Section 10 is what repos 3–5 consume.
>
> GitHub: `github.com/Dark417/1sde-databricks-02-infra`
> Build order position: **2 of 5.** Requires repo 1 published.

---

## 0. Read first

This repo is the only one that runs `terraform apply`. It provisions AWS (storage,
compute, scheduling, secrets plumbing) and the Databricks **workspace-level** objects
(catalog, schemas, volume, jobs, grants).

**Authoritative docs** in `docs/`: `00-design-doc.md` (especially §4.1 Free Edition
constraints and §6 repo layout), `02-data-contracts.md`.

**The two things that make this repo different from a generic Terraform repo:**
1. Databricks Free Edition exposes **no account-level API**. Any account-scoped
   resource is unbuildable here, and writing one produces a confusing runtime failure
   rather than a plan-time error. CI greps for them.
2. Cross-repo config handoff is via **SSM Parameter Store**, never
   `terraform_remote_state`. Remote state grants every consumer read access to every
   output; SSM gives per-parameter IAM.

---

## 1. Scope

### Owns
- Terraform state backend config (bucket + DynamoDB lock created by hand, §9.1).
- S3: `fin-lake-raw`, `fin-lake-serving`.
- IAM: Terraform execution role, ECS task role, **GitHub Actions OIDC roles for all
  five repos**.
- ECR repository for the ingest image.
- ECS cluster + task definition + EventBridge schedule (created **disabled**).
- CloudWatch log groups.
- Databricks workspace-level: catalog `fin`, schemas, volume, job definitions, grants.
- SSM parameters that repos 3–5 read.

### Does NOT own
- **Table DDL.** Liquibase in repo 1 creates tables. Terraform creates the
  catalog/schema/volume they live in, and stops there.
- Secret *values*. Secrets are created by hand (§9.2); Terraform references them as
  data sources so plaintext never enters state.
- Application code of any kind.
- The serving deployment (repo 5 deploys itself to Fly/Render).

### Boundary that will tempt you and must be refused
Do not add `databricks_sql_table` resources. Table lifecycle belongs to Liquibase.
Two tools owning the same object is how you get a `terraform destroy` that silently
drops a table Liquibase thinks it still manages.

---

## 2. Prerequisites from repo 1

| Input | Source | Why |
|---|---|---|
| `CATALOG`, `SCHEMA_*`, `VOLUME_LANDING` | repo 1 `names.py` | Terraform resource names must match **exactly**, or repo 4 writes to a catalog that does not exist |
| `RAW_BUCKET_DEFAULT`, `SERVING_BUCKET_DEFAULT` | repo 1 `names.py` | bucket names |
| `CONTRACTS_VERSION` | repo 1 §9.8 | published to SSM for repos 3–5 |
| ADR-001 result | repo 1 `docs/` | decides whether the ingest task needs Databricks Files API egress |

**Verification step, mandatory:** generate a test that reads the installed
`fin_lakehouse_contracts` package and asserts the Terraform `locals` match its
constants. Hardcoding `"fin"` in both places and hoping is not acceptable.

```python
# tests/test_names_match_contracts.py
from fin_lakehouse_contracts import names
import hcl2
def test_catalog_matches():
    tf = hcl2.load(open("locals.tf"))
    assert tf["locals"][0]["catalog"] == names.CATALOG
```

---

## 3. Tech baseline

```
Terraform      >= 1.9
AWS provider   ~> 5.60
Databricks     ~> 1.50   (WORKSPACE-level only)
Lint           terraform fmt, tflint
Security       tfsec (or checkov)
Tests          pytest + python-hcl2 for the contracts-match test
```

State: S3 backend + DynamoDB lock. One state file. Workspaces are not used — Free
Edition gives you one workspace and one metastore, so environment separation is by
**catalog prefix**, not by Terraform workspace. Document that in `README.md`.

---

## 4. Layered structure

```
1sde-databricks-02-infra/
├── AGENTS.md
├── backend.tf              # S3 backend, bucket name supplied at init
├── providers.tf            # aws + databricks (workspace auth)
├── locals.tf               # names mirrored from contracts
├── variables.tf
├── outputs.tf
├── main.tf                 # module wiring only, no resources
├── modules/
│   ├── storage/            # S3 buckets, lifecycle, public access block
│   ├── iam/                # execution role, task role, OIDC roles
│   ├── registry/           # ECR
│   ├── compute/            # ECS cluster, task def, log group
│   ├── schedule/           # EventBridge Scheduler
│   ├── databricks/         # catalog, schemas, volume, grants, jobs
│   └── params/             # SSM parameters (the repo's published interface)
├── envs/
│   └── dev.tfvars
├── tests/
└── .github/workflows/ci.yml
```

**Layer rule:** `main.tf` contains only `module` blocks and their wiring. A `resource`
in the root module is a review failure. Modules do not call other modules; the root
passes outputs between them.

---

## 5. Non-negotiable rules for the agent

1. **No account-level Databricks resources.** Forbidden: `databricks_metastore`,
   `databricks_metastore_assignment`, `databricks_metastore_data_access`, anything
   prefixed `databricks_mws_`, `databricks_account_*`. Free Edition has no account API
   (design doc §4.1). CI greps for these and fails the build.
2. **No `terraform_remote_state` anywhere.** CI greps.
3. **No `databricks_sql_table`.** Liquibase owns tables (§1).
4. **`schedule_enabled` defaults to `false`.** An enabled schedule pointing at
   unproven code burns the Free Edition daily quota and fills S3 with garbage. The
   human enables it after a successful manual run.
5. **No secret values in Terraform.** Use `data "aws_secretsmanager_secret_version"`.
   Any `aws_secretsmanager_secret_version` *resource* puts plaintext in state — never
   write one.
6. **Least privilege, literally.** The ECS task role gets `s3:PutObject` on
   `fin-lake-raw/*`. Not `s3:*`. Not the bucket ARN without `/*`. Not
   `s3:DeleteObject` — the raw zone is immutable and the task has no business deleting
   from it.
7. **Every S3 bucket:** versioning on, `block_public_access` all four flags true,
   SSE enabled, lifecycle rule to IA at 90 days.
8. **Every IAM policy is inline or customer-managed and scoped by ARN.** No AWS
   managed policies broader than `AmazonECSTaskExecutionRolePolicy`.
9. **CloudWatch log retention is set explicitly** (14 days). The default is "never
   expire," which is a slow-motion bill.
10. **Tag everything**: `project=fin-lakehouse`, `repo=1sde-databricks-02-infra`,
    `managed_by=terraform`, `env=dev`.
11. **Idempotency is a test.** A second `apply` must show zero changes. If a resource
    causes perpetual diff, fix it or add `lifecycle { ignore_changes }` with a comment
    explaining exactly why.

---

## 6. Features to generate

### F-1 · `modules/storage`
Two buckets. Raw: versioned, SSE-S3, all public access blocked, lifecycle
`STANDARD_IA` at 90d, and a bucket policy denying `s3:DeleteObject` to everything
except the Terraform role — the raw zone is the system of record and immutability is
the property that makes replay meaningful (design doc §8.1).

Serving: versioned, SSE-S3, all public access blocked. Read access is granted to the
repo-5 role, not to the public — the API reads it with credentials.

**Acceptance:** `tfsec` clean; a test asserts the deny-delete statement exists.

### F-2 · `modules/iam`
- `fin-lakehouse-tf` execution role (assumed by the human and by CI).
- `1sde-databricks-03-ingest-task` role: `s3:PutObject` on raw only,
  `secretsmanager:GetSecretValue` on the two named secrets, `logs:*` on its log group.
- Five GitHub Actions OIDC roles, one per repo, each scoped to
  `repo:Dark417/<repo-name>:*`. Trust policy uses
  `token.actions.githubusercontent.com` with a `sub` condition. A wildcard `sub` is a
  finding, not a shortcut.

**Acceptance:** a test asserts no policy document contains `"Action": "*"` or
`"Resource": "*"` outside of explicitly annotated exceptions.

### F-3 · `modules/registry`
ECR repo, image scanning on push, lifecycle policy keeping the last 10 images.

### F-4 · `modules/compute`
ECS Fargate cluster (no EC2 capacity provider). Task definition: 0.5 vCPU / 1 GB,
image from ECR pinned by **digest at deploy time**, not `:latest`. Environment from
`var.ingest_env`, secrets from Secrets Manager ARNs. Log group with 14-day retention.

**Acceptance:** task definition has no plaintext secret in `environment`; all secrets
go through `secrets` with `valueFrom`.

### F-5 · `modules/schedule`
EventBridge Scheduler, cron `0 6 * * ? *` UTC, target = the ECS task,
`state = var.schedule_enabled ? "ENABLED" : "DISABLED"`, default `false`.
Flexible time window OFF — you want a deterministic logical date.

**Acceptance:** `terraform plan` with defaults shows `state = "DISABLED"`.

### F-6 · `modules/databricks` 🔴
Workspace provider auth: `host` from `var.databricks_host`, `token` from a Secrets
Manager data source.

Resources:
- `databricks_catalog.fin`
- `databricks_schema` ×4 (`landing`, `bronze`, `silver`, `gold`)
- `databricks_volume.landing_edgar` — MANAGED volume, in `fin.landing`
- `databricks_grants` — the workspace principal gets `USE_CATALOG`, `USE_SCHEMA`,
  `CREATE_TABLE`, `MODIFY`, `SELECT`
- `databricks_job.daily` — task graph:

```
bronze_all ──┬─► silver_filing ──┬─► silver_company ──┐
             │                   └─► silver_fact ─────┼─► gold_all ─► export_serving
             └───────────────────────────────────────-┘
```
Max concurrency in this graph is 2. Free Edition caps job tasks at 5 concurrent
(design doc §4.1) — stay well inside it.

Each task references the repo-4 wheel **by pinned version**, never `latest`.

**Acceptance:**
- `grep -rE 'databricks_(metastore|mws_|account_)' *.tf modules/` returns nothing.
- Second `apply` shows zero changes.
- Job task concurrency ≤ 3.

### F-7 · `modules/params` — the published interface
One `aws_ssm_parameter` per published value. Exactly these, no more:

```
/fin-lakehouse/dbx/host
/fin-lakehouse/dbx/volume_path
/fin-lakehouse/dbx/warehouse_id
/fin-lakehouse/s3/raw_bucket
/fin-lakehouse/s3/serving_bucket
/fin-lakehouse/ecr/ingest_repo
/fin-lakehouse/contracts/version
/fin-lakehouse/landing_mode
/fin-lakehouse/iam/oidc_role_arn/<repo>     (×5)
```

**Rule:** adding a parameter is adding to a public interface. Every one needs a
comment saying which repo consumes it. An unconsumed parameter is deleted.

### F-8 · Bootstrap docs
`docs/BOOTSTRAP.md` — the chicken-and-egg problem: Terraform cannot create the bucket
holding its own state. Document the manual commands (§9.1) and note that these are the
only resources in the project not under Terraform, and why.

---

## 7. Testing requirements

| Check | Tool |
|---|---|
| Format | `terraform fmt -check -recursive` |
| Validity | `terraform validate` |
| Lint | `tflint --recursive` |
| Security | `tfsec` — zero HIGH/CRITICAL |
| Forbidden resources | `grep` gate (rule 1, 2, 3) |
| Names match contracts | `pytest tests/test_names_match_contracts.py` |
| Idempotency | manual: apply twice, second shows zero changes |

---

## 8. CI — `.github/workflows/ci.yml`

```
on: pull_request        -> fmt, validate, tflint, tfsec, grep gates, plan (comment on PR)
on: workflow_dispatch   -> apply   (MANUAL TRIGGER ONLY)
```
**`apply` is never automatic.** Not on merge to `main`, not on tag. This repo can
delete your data; a human presses the button. Say so in the README.

AWS auth via the OIDC role from F-2. Databricks PAT read from Secrets Manager at
runtime, never a GitHub secret.

---

## 9. EXECUTION — what you do manually

### 9.1 Bootstrap the state backend 🔴 (before anything)
```bash
export AWS_REGION=us-east-1
export ACCT=$(aws sts get-caller-identity --query Account --output text)
export TF_BUCKET=fin-lakehouse-tfstate-$ACCT

aws s3api create-bucket --bucket "$TF_BUCKET" --region "$AWS_REGION"
aws s3api put-bucket-versioning --bucket "$TF_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$TF_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws dynamodb create-table --table-name fin-lakehouse-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 9.2 Create secrets by hand 🔴
```bash
aws secretsmanager create-secret --name /fin-lakehouse/databricks/pat \
  --secret-string "dapi..."
aws secretsmanager create-secret --name /fin-lakehouse/sec/user-agent \
  --secret-string "fin-lakehouse-demo you@example.com"
```
The SEC rejects requests without a `User-Agent` carrying a real contact email. Use an
address you monitor.

### 9.3 Set a budget alarm
$10/month, email alert. The only realistic way this project costs money is a runaway
schedule. Do this before the first apply, not after.

### 9.4 Create the repo and wire the docs
```bash
gh repo create Dark417/1sde-databricks-02-infra \
  --private --add-readme --gitignore Terraform --license mit --clone
cd 1sde-databricks-02-infra
mkdir -p docs && cp ../design/00-design-doc.md ../design/02-data-contracts.md docs/
# pip cannot read s3:// URLs — download the wheel first (for the names-match test)
aws s3 cp "s3://$TF_BUCKET/wheels/" /tmp/wheels/ --recursive
pip install "fin-lakehouse-contracts==<CONTRACTS_VERSION>" --find-links /tmp/wheels/
```

### 9.5 First apply — read the plan
```bash
terraform init -backend-config="bucket=$TF_BUCKET"
terraform plan -var-file=envs/dev.tfvars -out=tf.plan
```
**Check by hand before applying:**
- [ ] zero `destroy` actions
- [ ] no `databricks_metastore*` / `databricks_mws_*` in the plan
- [ ] EventBridge schedule shows `state = "DISABLED"`
- [ ] every S3 bucket has all four public-access-block flags true
- [ ] no plaintext secret string appears in the plan output

```bash
terraform apply tf.plan
```

### 9.6 Hand back to repo 1 🔴
The catalog and schemas now exist. **Go back to repo 1 and run `liquibase update`.**
This is the one place the build order loops backward. Tables cannot be created before
their schemas exist, and Terraform does not create tables.

### 9.7 Verify in the Databricks UI
Catalog Explorer → `fin` → four schemas → `landing.edgar` volume present.
Then confirm Liquibase's `DATABASECHANGELOG` table appeared after 9.6.

### 9.8 Record what repos 3–5 need
```bash
aws ssm get-parameters-by-path --path /fin-lakehouse --recursive \
  --query 'Parameters[].[Name,Value]' --output table
```
Repos 3–5 read these at runtime. You should never paste these values into another
repo's source.

### 9.9 Enable the schedule — LAST
Only after repo 4 has run successfully by hand:
```bash
terraform apply -var-file=envs/dev.tfvars -var schedule_enabled=true
```

---

## 10. Published outputs — what repos 3–5 consume

| Output | Form | Consumed by |
|---|---|---|
| SSM `/fin-lakehouse/*` | Parameter Store | 3, 4, 5 at runtime |
| OIDC role ARNs | SSM + IAM | 3, 4, 5 CI |
| ECR repo URI | SSM | 3 (pushes image) |
| ECS task definition family | SSM | 3 (deploy target) |
| Databricks catalog/schemas/volume | live objects | 1 (Liquibase target), 4 |
| Databricks job id | SSM | 4 (updates task wheel version) |
| `fin-lake-serving` bucket | live | 4 (writes), 5 (reads) |

**Contract:** repos 3–5 read config from SSM at runtime. They do not hardcode ARNs,
bucket names, or hosts. A hardcoded ARN in a downstream repo is a review failure.

---

## 11. Definition of done

- [ ] `fmt`, `validate`, `tflint`, `tfsec` green
- [ ] Grep gates pass (no account-level Databricks, no remote_state, no sql_table)
- [ ] `test_names_match_contracts.py` green against the pinned contracts wheel
- [ ] `apply` twice → second shows zero changes
- [ ] Catalog, four schemas, and volume visible in Catalog Explorer
- [ ] Repo 1 `liquibase update` succeeded against them (§9.6)
- [ ] All SSM parameters populated
- [ ] Schedule exists and is **DISABLED**
- [ ] Budget alarm set

---

## 12. References

1. Databricks Terraform provider — https://registry.terraform.io/providers/databricks/databricks/latest/docs
2. Free Edition limitations (why no account-level resources) — https://docs.databricks.com/aws/en/getting-started/free-edition-limitations
3. `databricks_volume` — https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/volume
4. GitHub OIDC to AWS — https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
5. terraform-aws-modules (reference implementations worth reading) — https://github.com/terraform-aws-modules
6. tfsec rules — https://aquasecurity.github.io/tfsec/latest/checks/aws/s3/
