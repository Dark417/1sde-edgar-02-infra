# 1sde-edgar-02-infra

> **Part of the [EDGAR lakehouse](https://github.com/Dark417/1sde-edgar-06-chatbot#readme)
> project.** That README is the front door: the dataflow, the Databricks layers, how the
> chatbot answers, how the six repositories fit together, and what it costs — one diagram
> each.
>
> **Live:** [the site](https://edgar.xiaoxiaolei.com) ·
> [SEC EDGAR](https://www.sec.gov/edgar), the source of every figure.


Repo 2 of 6. Terraform for everything the others run on: the buckets, the container
registry, the Fargate cluster, the schedules, the IAM roles and the host that serves the
site and the chatbot. Nothing is created by hand, and an auto-apply refuses any plan that
would destroy or replace a resource.

Terraform for the EDGAR lakehouse: AWS storage, IAM, container build and
schedule, plus the Databricks **workspace-level** objects (catalog, schemas,
volume, grants, job). Repo 2 of 5.

This is the only repo that runs `terraform apply`.

## What it owns, and what it deliberately does not

Terraform owns the *containers*: the catalog, the four schemas, the volumes, the
buckets, the roles. It does not own **tables** — those belong to Liquibase in
repo 1 — and as of 2026-08-02 it no longer owns the **Databricks job** either.

That last one is worth reading before you reach for it again. An ECS task
definition references its image by URI, so this repo can declare the container
without knowing what runs inside. A Databricks job offers no equivalent seam:
its tasks name the package, entry point, parameters and dependency edges, which
*is* repo 4's interface. Declaring it here meant restating another repo's
internals, and every field was wrong — wrong wheel filename, wrong package name,
six invented entry points against one real dispatcher, six tasks against four.
The job was live and would have failed on its first run. Repo 4's Asset Bundle
owns it now; this repo still provides the `wheels` volume it publishes into. There are no `databricks_sql_table` resources
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

`apply` runs automatically when a pull request merges to `main` — but the apply
job **re-plans against current state and aborts on any destroy or replace**
before it touches anything.

That guard is the entire safety argument, and it is worth being precise about
why. The reviewed plan on the PR is what authorises the merge, but state can
move between review and merge: a concurrent apply, a console change, a drifted
resource. So the apply job discards the PR's plan and produces its own. If that
plan would destroy or replace anything, the job fails and waits for a human,
because on this project a destroy means dropping a catalog with 13
Liquibase-managed tables inside it.

`workflow_dispatch` remains available for out-of-band applies — drift
correction, or re-running after a manual change — and still requires typing
`apply` to confirm. Both paths are gated on the `dev` GitHub environment.

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
