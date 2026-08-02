# Working notes — decisions, tradeoffs, open questions

Running log for the EDGAR lakehouse build. Captures the reasoning behind choices
that are not obvious from the code, the measurements that were expensive to
obtain, and the decisions still outstanding.

Last updated: **2026-08-01**.

---

## 1. Data source: SEC EDGAR, scheduled pull

**Not a subscription.** SEC offers no push, webhook, or subscription for these
endpoints — there is no API key and no account. Authentication is a `User-Agent`
header carrying a real contact email; anonymous clients get `403`. Rate limit is
~10 req/s, self-capped at 5.

Three streams, and they are not the same shape:

| Stream | Format | Note |
|---|---|---|
| `filing_index` | fixed-width `.idx` | 11 header lines then positional columns — **not CSV**; splitting on whitespace breaks on company names |
| `company_submissions` | JSON | stored verbatim as one string |
| `company_concept` | JSON | stored verbatim as one string |

**Only `filing_index` is backfillable.** `submissions` and `companyconcept` take
no date parameter — they always return current full history, so "backfill to a
past date" is meaningless for them. This is why `AGENTS.md` §9.9's loop pulls
`--stream filing_index` only.

Consequence worth having an answer ready for: every daily run re-fetches ~26 MB
of near-identical snapshot data. The bitemporal MERGE dedups it correctly in
silver, but the landing zone grows linearly with almost pure redundancy.

---

## 2. Measured source facts (probed live, not estimated)

Re-probing costs 25 minutes of rate-limited requests. Recorded here so nobody
has to.

| Measurement | Value |
|---|---|
| Daily index (2026-07-31) | 1.12 MB raw, **105 KB gzip** (10.7×), **5,772 filings** |
| One large filer, all 15 concepts (AAPL) | 410 KB raw, **2,918 fact rows**, 1,165 distinct periods |
| `filing_index` backfill (150 weekdays) | ~160 MB raw / 15 MB gzip, ~825,000 rows |
| Full concept pass (7,500 requests, ~25 min) | ~120–205 MB raw / 12–20 MB gzip |
| Steady state, all three streams | ~20–26 MB gzip/day → ~8 GB/year |
| `silver.financial_fact` after backfill | ~600k–900k rows |

Two things this surfaced:

**The illustrative row counts in `docs/02-data-contracts.md` §5 understate
reality by roughly 7×.** It shows `financials_current: 41250`, which is 82
periods per company; AAPL alone has 1,165. Real output is nearer 250k–350k rows.
Harmless as an example, but the arithmetic doesn't survive scrutiny.

**`CostOfRevenue` 404s for Apple** (it reports `CostOfGoodsAndServicesSold`).
Good live confirmation that the "404 → `None`" design is load-bearing, not
defensive padding.

**The daily index is the whole market**, not the 500-company universe — 5,772
filings/day across thousands of CIKs, with no filter to the universe anywhere in
the pipelines spec. Defensible (`gold.filing_activity_daily` is genuinely
market-wide) but it means `silver.filing` holds ~825k rows while
`silver.company` holds 500, and joining them on `accession_number` only matches
for the universe subset. Decide on purpose, not at demo time.

---

## 3. Scale: stay small, answer the question verbally

**Decision:** keep the 500-company REST fan-out. Do **not** switch data sources
before the interview.

**Options considered.** Two bulk channels were verified live and would give
~100× more data *without leaving SEC*:

- **XBRL `frames` API** — `data.sec.gov/api/xbrl/frames/us-gaap/Assets/USD/CY2025Q4I.json`
  returns **6,014 companies in one 803 KB request**. Fifteen concepts × ~68
  quarters ≈ 1,020 requests covering all ~6,000 filers, versus the current 7,500
  requests for 500 companies.
- **DERA Financial Statement Data Sets** — quarterly bulk ZIPs, 2009Q2 to
  present, 5–122 MB each (~4 GB total, ~250–400M fact rows in `num.txt`).

**Why not adopt them:** four of five repos are unbuilt and the interview is days
away. A finished end-to-end pipeline over 750k rows demonstrates more than a
half-built one over 300M.

**The tradeoff, stated honestly:** EDGAR is strong on *modelling* (genuine
bitemporality, restatements, justified SCD-2, real messy formats) and weak on
*scale/performance* (750k rows never justifies liquid clustering, Z-ordering, or
a shuffle-tuning discussion). We are trading a performance story for a modelling
story, deliberately.

**The answer to give when asked "how does this scale?"** — "500 companies via
the REST fan-out is a deliberate demo-scale choice. Production swaps to the
frames endpoint, 6,000 filers per request, or the DERA quarterly bulk sets at
~300M facts. Nothing in silver or gold changes because the landing contract is
identical." Delivered with the measured numbers, that beats actually having
300M rows, because it shows a choice rather than a default.

---

## 4. Repo 2 structure: root module vs seven leaf modules

**The root files are not optional.** `backend.tf`, `providers.tf` and
`imports.tf` can only exist in a root module; `variables.tf` and `outputs.tf`
are the CLI surface. Modules declare `required_providers` but never configure a
provider — a `provider` block in a child module blocks `count`/`for_each` on it
and makes it impossible to remove cleanly.

**The module split is a judgment call, and it is fair to push back on it.**
Every module is instantiated exactly once, so the usual reuse justification does
not apply. What it actually buys:

- **It forced two dependency cycles into the open.** IAM must grant access to a
  log group and task definition that `compute` creates; `storage`'s bucket
  policy needs IAM's role ARN. Because modules declare their inputs, the cycles
  were visible immediately and were broken deliberately — passing deterministic
  *names* into `iam` so it constructs the ARNs itself. Flat, that coupling is
  invisible until it breaks.
- **`iam` is genuinely large** — 14 resources plus 14 data sources, more than
  half the repo's complexity.
- **Blast radius becomes addressable** — `-target=module.databricks` reasons
  about UC objects without re-planning all of AWS, which matters when the
  catalog holds 13 Liquibase-owned tables.

Execution order (Terraform parallelises; these are waves, not steps):

```
wave 1   registry  ‖  databricks     ← no dependencies
wave 2   iam                          ← needs the ECR ARN
wave 3   storage   ‖  compute         ← both need iam
wave 4   schedule                     ← needs cluster + task definition
wave 5   params                       ← needs identifiers from nearly everything
```

---

## 5. Deviations from `AGENTS.md` (three, all deliberate)

1. **Extra volume `edgar.landing.wheels`.** Not in §6 F-6. Repo 4's job tasks
   install a private wheel that is not on PyPI and must be readable from a
   volume path. Kept separate from the landing volume, which holds
   externally-landed data and should not also hold build artefacts.
2. **Two extra SSM parameters** — `/edgar-lakehouse/ecs/task_family` and
   `/edgar-lakehouse/dbx/job_id`. **§10 and F-7 contradict each other**: §10
   lists both as SSM-published values consumed by repos 3 and 4, F-7 says
   "exactly these, no more" and omits them. Both are genuinely consumed, so they
   are published and flagged rather than dropped. *This contradiction is still
   unresolved in the spec.*
3. **`bronze_all → gold_all` edge omitted** from the job graph. Drawn in F-6 but
   transitively implied via silver; a redundant edge hides the real structure.

---

## 6. AWS: dedicated account, us-east-2, no static keys

**Dedicated member account `<AWS_ACCOUNT_ID>`** ("demo") under organization
`o-q6k3jav7zz`. The management account `381492022873` holds unrelated SageMaker
work — which is exactly the arrangement AWS advises against, since SCPs do not
apply to a management account.

**Region is `us-east-2`**, matching `metastore_aws_us_east_2`. On Free Edition
the compute is serverless inside Databricks' own account, so buckets anywhere
else bill cross-region transfer on every export repo 4 writes and repo 5 reads.
Note the CLI *default* profile is `us-west-2` — always pass `--profile edgar`.

**Access is by role assumption, never access keys.** Profile `edgar` assumes
`OrganizationAccountAccessRole`; credentials are short-lived and minted on
demand. An `edgar-admin` IAM user exists for console use with **no access keys**
— deliberately, since static keys are the same failure mode as the Databricks
PAT currently sitting in `liquibase.properties`.

**Gotchas discovered the hard way:**

- **Root users cannot assume roles.** "Switch role" fails from a root session
  with a misleading permissions error. Sign in as a non-root IAM identity.
- An org has exactly **one** management account, permanently. There is no
  operation to promote a member account or transfer the role. `demo` being a
  member account is not a limitation — it is where workloads belong.
- `us-east-2` requires `--create-bucket-configuration LocationConstraint`;
  `us-east-1` is the only region that rejects that flag.
- `*.tfvars` is gitignored by GitHub's default Terraform template, which would
  have made CI's `-var-file=envs/dev.tfvars` fail. Negated with `!envs/*.tfvars`.

**Safety net:** `allowed_account_ids = ["<AWS_ACCOUNT_ID>"]` in `dev.tfvars` makes
Terraform refuse to run against any other account, so a forgotten profile is a
clean error rather than a project built alongside the SageMaker work.

---

## 7. Free tier: already expired for this organization

**The 12-month free tier is gone permanently.** The management account was
created 2024-01-15, so it expired January 2025 — and because billing is
consolidated (`FeatureSet: ALL`), free tier is calculated at the **payer**
level. Creating a new member account does **not** start a fresh clock. Any
future member account inherits the same expired status.

What survives are the **always-free** tiers, which never expire: Lambda (1M
requests + 400,000 GB-seconds/month), CloudFront (1 TB egress + 10M requests),
DynamoDB (25 GB + 25 RCU/WCU), SQS/SNS (1M requests), SSM Standard parameters.

Expected running cost for the lakehouse: **~$1–3/month**, dominated by Secrets
Manager at $0.40/secret/month × 2. The spec's $10 budget alarm is well
calibrated.

---

## 8. Serving layer: not on ECS

**The UI is not in ECS and never was.** Repo 5 deploys to **Fly.io (or
Render)**, always-on free tier. ECS here runs exactly one thing — the repo 3
ingest batch job — and it is not even a service: there is no `aws_ecs_service`,
no load balancer, and the task security group has **zero ingress rules** with a
single egress rule on 443. EventBridge starts a task, it works ~25 minutes, it
exits.

The reason: an always-on ECS service needs an ALB for stable HTTPS, and an ALB
alone is ~$16–18/month — several times this entire project's cost.

### Future FastAPI / AI-agent backend — ECS vs Lambda

| | Lambda + Function URL | ECS Fargate + ALB |
|---|---|---|
| Cost at low traffic | **$0** (always-free tier) | **~$26/mo** ($9 Fargate + $17 ALB) |
| Scale to zero | yes | no |
| Max duration | **15 min hard cap** | unlimited |
| Cold starts | 1–3s zip, 2–5s container | none |
| Streaming | yes via Function URL (**not** API Gateway — 30s cap) | yes, but raise ALB idle timeout from 60s |
| WebSockets | no | yes |
| Terraform resources | ~3 | ~12–15 |

**Recommendation: use both.** Lambda for the API and UI (free at this traffic),
and for long agent runs drop a job on SQS and have **`ecs:RunTask` launch a
Fargate task on demand** — pay-per-second, zero idle cost, exactly how the
ingest job already works. A five-minute agent run costs about half a cent. The
existing ECS cluster is reused as-is since clusters are free.

Switch to a real ECS service only for WebSockets, unacceptable cold starts,
persistent in-memory state, or steady traffic. **Give it its own Terraform
state** — the lakehouse and an agent backend have different lifecycles, and
repo 2's state governs a catalog holding 13 Liquibase-managed tables.

---

## 9. Operational hazards hit during this build

**Two Claude sessions worked this project concurrently.** During a repo rename,
one session wrote files into the *old* directory name, silently creating a ghost
directory instead of failing. Resolved by consolidating and deleting the ghost.
If sessions run in parallel again, re-check directory names before writing.

**The `fin` → `edgar` rename touched everything** — repos (local and GitHub),
catalog, Python package (`edgar_lakehouse_contracts`), buckets, SSM namespace.
`test_names_match_contracts.py` earned its keep here: it parses the real
`locals.tf` and compares to the installed wheel, so all eight mirrored constants
moving at once was caught rather than discovered at apply time.

**Unity Catalog objects were hand-created before Terraform existed**, so
`imports.tf` adopts the catalog, four schemas and landing volume. Without it the
first apply fails with "already exists". Tables are deliberately **not**
imported — they belong to Liquibase, and dual ownership is how a `destroy`
silently drops something the other tool thinks it manages.

---

## 10. Open decisions

- [ ] **ADR-001 (landing transport)** is still **UNRESOLVED**. Defaults to
      `volume`. Run the `dbutils.fs.ls("s3://edgar-lake-raw/")` probe to decide
      whether Auto Loader reads S3 directly.
- [ ] **§10 vs F-7 contradiction** in `AGENTS.md` about the SSM parameter list —
      the spec should be corrected either way.
- [ ] **Should `filing_index` be filtered to the CIK universe?** Currently the
      whole market lands in `silver.filing`.
- [ ] **Move `demo` into an OU** so an SCP can pin it to `us-east-2` or cap
      spend. Currently sits directly under Root.
- [ ] **Fix the illustrative row counts** in `docs/02-data-contracts.md` §5.

## 11. Next steps

1. **AWS bootstrap** (`docs/BOOTSTRAP.md`) — state bucket + lock table in
   `us-east-2`, then the two secrets, then the budget alarm. Nothing can apply
   until this exists.
2. **Rotate the Databricks PAT.** The current one is in gitignored
   `changelog/liquibase.properties` and has been pasted into chat. Generate a
   fresh one for Secrets Manager and revoke the old.
3. **Enable MFA on the `<AWS_ACCOUNT_ID>` root user** — currently off.
4. **First `terraform apply`** — check the plan by hand: zero destroys, the
   catalog/schemas/volume showing as *import* not create, schedule `DISABLED`,
   job `PAUSED`, no plaintext secrets in the output.
5. **Set GitHub repo variables** `AWS_ROLE_ARN` and `TF_STATE_BUCKET`. CI will
   fail until both exist — a bootstrap ordering problem, not a broken pipeline.
6. **Repos 3 → 4 → 5.** Repo 3 currently contains only a `.git` directory.
