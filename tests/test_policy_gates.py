"""Static gates over the Terraform source.

These run as pytest so they are enforceable locally, and are mirrored as grep
steps in CI (AGENTS.md §7) so a broken pytest environment cannot silently skip
them.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

TF_FILES = sorted(
    p for p in REPO_ROOT.rglob("*.tf") if ".terraform" not in p.parts
)


def _rel(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


def _code_only(line: str) -> str:
    """Strip HCL comments so the gates match code rather than prose.

    Without this, a comment explaining *why* a resource is forbidden trips the
    very gate that forbids it — which would push the explanation out of the
    codebase and leave a bare rule nobody can trace back to a reason.
    """
    return line.split("#", 1)[0].split("//", 1)[0]


def test_terraform_files_were_found() -> None:
    """Guard against a path bug silently turning every gate below into a no-op."""
    assert len(TF_FILES) >= 15, f"expected the full module tree, found {len(TF_FILES)} files"


# ---------------------------------------------------------------------------
# Rule 1 / 2 / 3 — forbidden resources
# ---------------------------------------------------------------------------

# Assembled from fragments so that this file does not itself contain the literal
# tokens the CI grep searches for.
FORBIDDEN = {
    "account-level Unity Catalog (Free Edition has no account API)": re.compile(
        r"databricks_" + r"(metastore|mws_|account_)"
    ),
    "cross-repo state coupling (rule 2: use SSM)": re.compile(
        r"terraform_" + r"remote_state"
    ),
    "table lifecycle owned by Liquibase, not Terraform (rule 3)": re.compile(
        r"databricks_" + r"sql_table"
    ),
}


@pytest.mark.parametrize("reason", list(FORBIDDEN))
def test_no_forbidden_resources(reason: str) -> None:
    pattern = FORBIDDEN[reason]
    hits = [
        f"{_rel(p)}:{i}"
        for p in TF_FILES
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if pattern.search(_code_only(line))
    ]
    assert not hits, f"forbidden — {reason}: {hits}"


# ---------------------------------------------------------------------------
# F-2 acceptance — least privilege
# ---------------------------------------------------------------------------

BARE_ACTIONS = re.compile(r'actions\s*=\s*\[\s*"\*"\s*\]')
BARE_RESOURCES = re.compile(r'resources\s*=\s*\[\s*"\*"\s*\]')
JSON_WILDCARD = re.compile(r'"(Action|Resource)"\s*:\s*"\*"')
ANNOTATION = "allow-wildcard-resource:"


def test_no_wildcard_actions() -> None:
    """`Action: "*"` has no legitimate use here and gets no exemption path."""
    hits = [
        f"{_rel(p)}:{i}"
        for p in TF_FILES
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if BARE_ACTIONS.search(_code_only(line)) or JSON_WILDCARD.search(_code_only(line))
    ]
    assert not hits, f"wildcard actions are never permitted: {hits}"


def test_wildcard_resources_are_annotated() -> None:
    """`Resource: "*"` is sometimes unavoidable, but never unexplained.

    A handful of AWS calls (ecr:GetAuthorizationToken) genuinely have no
    resource ARN, and a provisioning role cannot scope to ARNs it has not
    created yet. Those are allowed — but each one must carry an
    ``# allow-wildcard-resource:`` comment within the preceding 10 lines saying
    why, so the exception is a decision on the record rather than a default.
    """
    unannotated: list[str] = []

    for path in TF_FILES:
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            if not BARE_RESOURCES.search(_code_only(line)):
                continue
            window = lines[max(0, i - 10) : i]
            if not any(ANNOTATION in w for w in window):
                unannotated.append(f"{_rel(path)}:{i + 1}")

    assert not unannotated, (
        "wildcard resources without an '# allow-wildcard-resource:' justification: "
        f"{unannotated}"
    )


def test_oidc_trust_is_scoped_to_a_named_repository() -> None:
    """A `sub` of "*" would let any GitHub repo on earth assume the role."""
    iam = (REPO_ROOT / "modules" / "iam" / "main.tf").read_text(encoding="utf-8")
    assert 'values     = ["repo:${var.github_owner}/${each.value}:*"]' in iam or (
        "repo:${var.github_owner}/${each.value}:*" in iam
    ), "OIDC sub condition must name the owner and repository"
    assert 'values = ["*"]' not in iam


# ---------------------------------------------------------------------------
# F-1 acceptance — raw zone immutability
# ---------------------------------------------------------------------------


def test_raw_bucket_denies_deletes() -> None:
    storage = (REPO_ROOT / "modules" / "storage" / "main.tf").read_text(encoding="utf-8")
    assert "DenyDeleteExceptTerraformRole" in storage
    assert "s3:DeleteObject" in storage
    assert "s3:DeleteObjectVersion" in storage
    assert 'test     = "ArnNotEquals"' in storage


def test_every_bucket_blocks_public_access_on_all_four_flags() -> None:
    storage = (REPO_ROOT / "modules" / "storage" / "main.tf").read_text(encoding="utf-8")
    for flag in (
        "block_public_acls",
        "block_public_policy",
        "ignore_public_acls",
        "restrict_public_buckets",
    ):
        # One per bucket: raw and serving.
        assert storage.count(f"{flag} ") == 2, f"{flag} must be set true on both buckets"
    assert "false" not in storage.split("public_access_block")[1].split("}")[0]


# ---------------------------------------------------------------------------
# Rule 4 / F-5 acceptance — nothing runs on a timer by default
# ---------------------------------------------------------------------------


def test_schedule_defaults_to_disabled() -> None:
    root_vars = (REPO_ROOT / "variables.tf").read_text(encoding="utf-8")
    block = root_vars.split('variable "schedule_enabled"')[1].split("\n}")[0]
    assert "default     = false" in block

    schedule = (REPO_ROOT / "modules" / "schedule" / "main.tf").read_text(encoding="utf-8")
    assert 'var.schedule_enabled ? "ENABLED" : "DISABLED"' in schedule

    # The Databricks job's pause state is no longer asserted here: the job moved
    # to repo 4's Asset Bundle on 2026-08-02, so its schedule is repo 4's to
    # keep paused. See test_no_databricks_job_here for the replacement check.


# ---------------------------------------------------------------------------
# Rule 5 — no secret values in state
# ---------------------------------------------------------------------------


def test_no_secret_version_resources() -> None:
    """The data source is fine; the resource writes plaintext into state."""
    hits = [
        f"{_rel(p)}:{i}"
        for p in TF_FILES
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if re.search(r'^\s*resource\s+"aws_secretsmanager_secret_version"', line)
    ]
    assert not hits, f"secret values would land in Terraform state: {hits}"


# ---------------------------------------------------------------------------
# §4 layer rule — the root module wires modules, it does not declare resources
# ---------------------------------------------------------------------------


def test_root_module_declares_no_resources() -> None:
    root_tf = [p for p in TF_FILES if p.parent == REPO_ROOT]
    hits = [
        f"{_rel(p)}:{i}"
        for p in root_tf
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if re.match(r'^\s*resource\s+"', line)
    ]
    assert not hits, f"root module must contain only module blocks and wiring: {hits}"


def test_modules_do_not_call_other_modules() -> None:
    """The root passes outputs between modules; modules stay leaves."""
    hits = [
        f"{_rel(p)}:{i}"
        for p in TF_FILES
        if p.parent != REPO_ROOT
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if re.match(r'^\s*module\s+"', line)
    ]
    assert not hits, f"modules must not call other modules: {hits}"


# ---------------------------------------------------------------------------
# F-6 acceptance — job graph stays inside the Free Edition concurrency cap
# ---------------------------------------------------------------------------


def test_no_databricks_job_here() -> None:
    """The job definition belongs to repo 4's Asset Bundle, not to this repo.

    Replaces an earlier test that verified this repo's own job DAG stayed inside
    the Free Edition concurrency cap. That test passed happily while the job it
    checked named a package that did not exist, six entry points against a single
    real dispatcher, and six tasks against four — it validated the shape of a
    graph nobody could run.

    A Databricks job's tasks name the package, entry point and parameters, so
    declaring one here restates repo 4's internals across a repo boundary. The
    only durable check is that this repo declares no job at all; whether the
    graph fits Free Edition is repo 4's test to own, next to the code it
    describes.
    """
    hits = [
        f"{_rel(p)}:{i}"
        for p in TF_FILES
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if re.match(r'^\s*resource\s+"databricks_job"', _code_only(line))
    ]
    assert not hits, (
        "databricks_job belongs to repo 4's bundle (root AGENTS.md law 2). "
        f"Found: {hits}"
    )
