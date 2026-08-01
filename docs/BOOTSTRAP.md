# Bootstrap — the resources Terraform cannot create

Terraform stores its state in an S3 bucket. It cannot create the bucket that
holds its own state, because it would have to write the state of that creation
somewhere — and that somewhere is the bucket it has not made yet. The lock table
has the same problem.

So exactly four things in this project are created by hand and are **not** under
Terraform management. That number should never grow. Anything else you find
yourself creating in the console is a bug in this repo, not a bootstrap step.

| Resource | Why it is manual |
|---|---|
| `edgar-lakehouse-tfstate-$ACCT` S3 bucket | Holds the state of everything else |
| `edgar-lakehouse-tflock` DynamoDB table | Guards concurrent applies against that state |
| `/edgar-lakehouse/databricks/pat` secret | A secret *value* in Terraform would land in state (rule 5) |
| `/edgar-lakehouse/sec/user-agent` secret | Same |

## 0. Which account, and how you reach it

This project lives in a **dedicated member account**, `806168459926`, created
under the organization so that nothing here can touch the management account's
unrelated work. You never need its root password for day-to-day use:
Organizations created an `OrganizationAccountAccessRole` in it, and the `edgar`
CLI profile assumes that role from the management-account credentials.

```ini
# ~/.aws/config
[profile edgar]
role_arn       = arn:aws:iam::806168459926:role/OrganizationAccountAccessRole
source_profile = default
region         = us-east-2
output         = json
```

```bash
aws sts get-caller-identity --profile edgar
# -> arn:aws:sts::806168459926:assumed-role/OrganizationAccountAccessRole/...
```

**Console access**, when you need to look at something: sign in to the
management account, then use the account menu → *Switch role* with account
`806168459926`, role `OrganizationAccountAccessRole`. The root email
(`xxlei1997@gmail.com`) has no password set — you would have to use *Forgot
password* to create one, which is worth doing once purely so you can enable MFA
on it, and then not using again.

**Region is `us-east-2` throughout.** Not arbitrary: the Databricks metastore is
`metastore_aws_us_east_2`, and Free Edition compute is serverless inside
Databricks' own account. Buckets anywhere else mean every exported byte crosses
a region boundary.

`envs/dev.tfvars` pins `allowed_account_ids = ["806168459926"]`, so Terraform
refuses to run if your shell resolves to any other account. A forgotten profile
is a clean error instead of a project built in the wrong place.

## 1. State backend

Note `--profile edgar` on every command. Without it these land in the management
account, and the bucket name would embed the wrong account id.

```bash
export AWS_PROFILE=edgar
export AWS_REGION=us-east-2
export ACCT=$(aws sts get-caller-identity --query Account --output text)   # 806168459926
export TF_BUCKET=edgar-lakehouse-tfstate-$ACCT

# us-east-2 requires an explicit LocationConstraint; us-east-1 is the one region
# that rejects it. Omitting this here is the usual first-run failure.
aws s3api create-bucket --bucket "$TF_BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-bucket-versioning --bucket "$TF_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$TF_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws dynamodb create-table --table-name edgar-lakehouse-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Versioning on the state bucket is not optional. It is the only thing standing
between a corrupted apply and a rebuilt-from-scratch project.

## 2. Secrets

```bash
export AWS_PROFILE=edgar
export AWS_REGION=us-east-2

aws secretsmanager create-secret --name /edgar-lakehouse/databricks/pat \
  --secret-string "dapi..."

aws secretsmanager create-secret --name /edgar-lakehouse/sec/user-agent \
  --secret-string "edgar-lakehouse-demo you@example.com"
```

Generate a **fresh** PAT for this rather than reusing the one currently sitting
in `changelog/liquibase.properties` — that one has been pasted around and should
be revoked once Liquibase is pointed at its replacement.

The SEC returns `403` to any client whose `User-Agent` does not carry a real
contact address, so this is an access credential in practice even though it
looks like a formality. Use an address you actually monitor — if your crawler
misbehaves, that mailbox is where you find out.

## 3. Budget alarm — do this before the first apply, not after

$10/month, email alert. The only realistic way this project costs real money is
a schedule left enabled against code that loops. Setting the alarm afterwards
means finding out at the end of the month.

## 4. Adopting the hand-created Unity Catalog objects

The catalog, its four schemas and the landing volume already exist: they were
created through the SQL API on 2026-08-01 so that repo 1's `liquibase update`
had somewhere to build its tables. `imports.tf` adopts them on the first apply.

Verify before you plan:

```bash
databricks catalogs list -o json | jq -r '.[].name'
databricks schemas list edgar -o json | jq -r '.[].full_name'
databricks volumes list edgar landing -o json | jq -r '.[].full_name'
```

You should see `edgar`; `edgar.{landing,bronze,silver,gold}`; and
`edgar.landing.edgar`. If any is missing, fix `imports.tf` rather than letting
Terraform create a duplicate alongside it.

Delete `imports.tf` after the first successful apply. Import blocks that
reference objects already in state are ignored, but one that references an
object which has since been renamed is a plan-time failure with a confusing
message.

## 5. First plan — check by hand before applying

```bash
terraform init -backend-config="bucket=$TF_BUCKET"
terraform plan -var-file=envs/dev.tfvars -out=tf.plan
```

- [ ] zero `destroy` actions
- [ ] the catalog, four schemas and volume show as **import**, not create
- [ ] EventBridge schedule shows `state = "DISABLED"`
- [ ] the Databricks job shows `pause_status = "PAUSED"`
- [ ] every S3 bucket has all four public-access-block flags true
- [ ] no plaintext secret appears anywhere in the plan output

```bash
terraform apply tf.plan
```

## 6. Then hand back to repo 1

This is the one place the build order loops backward. Repo 1's Liquibase has
already run against the hand-created schemas, so on a clean rebuild you would
run it *here* — after Terraform creates the containers and before repo 4 expects
tables to exist.
