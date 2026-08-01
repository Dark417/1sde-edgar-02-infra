# 1sde-databricks-edgar-02-infra

Terraform for the EDGAR lakehouse: AWS storage, IAM, container build and
schedule, plus the Databricks **workspace-level** objects (catalog, schemas,
volume, grants, job). Repo 2 of 5.

This is the only repo that runs `terraform apply`.

## What it owns, and what it deliberately does not

Terraform owns the *containers*: the catalog, the four schemas, the volumes, the
job definition, the buckets, the roles. It does not own **tables** — those
belong to Liquibase in repo 1. There are no `databricks_sql_table` resources
here and CI fails the build if one appears. Two tools owning the same object is
how you get a `terraform destroy` that silently drops a table the other tool
still thinks it manages.

It also does not own secret *values*. Those are created by hand and read through
data sources, so plaintext never enters Terraform state.

## Two things that make this repo unusual

**Free Edition has no account-level API.** Any account-scoped Databricks
resource is unbuildable here and fails at *runtime* rather than at plan time,
which is a miserable way to find out. CI greps for the whole family of them.

**Cross-repo config goes through SSM Parameter Store, never
`terraform_remote_state`.** Remote state would give every consumer read access
to every output in this state file. SSM gives per-parameter IAM, so repo 5 can
read the serving bucket name without also being able to enumerate the project's
IAM roles. The published interface is `modules/params`; every parameter carries a
comment naming its consumer, and an unconsumed parameter gets deleted.

## Environments

Terraform workspaces are not used. Free Edition gives you one workspace and one
metastore, so environment separation would have to be by catalog name rather
than by state file — and a second catalog is not something this project needs.
One state file, one environment, `envs/dev.tfvars`.

## Getting started

Read [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) first. Four resources have to exist
before Terraform can run at all, and the Unity Catalog objects already exist and
are adopted via `imports.tf` rather than created.

```bash
terraform init -backend-config="bucket=edgar-lakehouse-tfstate-$ACCT"
terraform plan -var-file=envs/dev.tfvars -out=tf.plan
terraform apply tf.plan
```

## Safety posture

`apply` is never automatic — not on merge to `main`, not on tag. The workflow is
`workflow_dispatch` only and requires you to type `apply` to confirm. The PR
pipeline additionally fails if the plan contains any destroy action.

`schedule_enabled` defaults to `false`, and both the EventBridge schedule and
the Databricks job are created dormant. An enabled schedule pointing at unproven
code burns the Free Edition daily quota and fills S3 with garbage. A human flips
the switch after watching a manual run succeed.

## Tests

```bash
pip install -r requirements-dev.txt --find-links /tmp/wheels/
pytest tests/ -v
```

`test_names_match_contracts.py` parses the real `locals.tf` and asserts every
mirrored name equals the installed `edgar_lakehouse_contracts` constant. Repo 2
cannot import Python at plan time, so those names are necessarily duplicated;
this test is what keeps the duplication honest. It earned its keep on
2026-08-01, when the project was renamed `fin` → `edgar` and all eight constants
moved at once.

`test_policy_gates.py` enforces the rules that are easy to state and easy to
erode: no wildcard IAM actions, no unexplained wildcard resources, raw-zone
deletes denied, schedules dormant by default, no resources in the root module,
and a job graph whose real peak concurrency stays inside the Free Edition cap.

## Known deviations from AGENTS.md

Three, all deliberate and none silent:

1. **A second volume, `edgar.landing.wheels`.** Not named in §6 F-6. Repo 4's job
   tasks install a private wheel that is not on PyPI, so it must be readable from
   a volume path. Kept separate from the landing volume, which holds
   externally-landed data and should not also hold build artefacts.
2. **Two extra SSM parameters**, `/edgar-lakehouse/ecs/task_family` and
   `/edgar-lakehouse/dbx/job_id`. §10 lists both as SSM-published values consumed
   by repos 3 and 4, but F-7 says "exactly these, no more" and omits them. The
   sections contradict each other; both are genuinely consumed, so they are
   published and flagged here rather than dropped.
3. **The `bronze_all → gold_all` edge is omitted** from the job graph. It is drawn
   in F-6 but is transitively implied by the path through silver, and a redundant
   edge hides the real dependency structure.
