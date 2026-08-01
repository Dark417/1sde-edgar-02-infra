"""Terraform's mirrored names must equal the contracts package exactly.

Repo 2 cannot import Python at plan time, so the catalog, schema, bucket and
volume names are restated as Terraform locals. Restating a value is duplicating
it, and duplicated values drift. This test is what makes the duplication safe:
it parses the real ``locals.tf`` and compares every mirrored constant to the
installed ``edgar_lakehouse_contracts`` wheel.

Hardcoding "edgar" in both places and hoping is explicitly not acceptable
(AGENTS.md §2). This test earned its keep on 2026-08-01, when the project was
renamed fin -> edgar and every one of these constants moved at once.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import hcl2
import pytest
from edgar_lakehouse_contracts import names

REPO_ROOT = Path(__file__).resolve().parents[1]
LOCALS_TF = REPO_ROOT / "locals.tf"


@pytest.fixture(scope="module")
def mirrored() -> dict[str, Any]:
    """The first ``locals`` block: the literal mirrors of the contracts package.

    Block ordering matters. Block 0 is reserved for plain literals; derived
    values live in block 1 so that an interpolated string can never be compared
    against a package constant and accidentally pass.
    """
    with LOCALS_TF.open(encoding="utf-8") as fh:
        parsed = hcl2.load(fh)
    return parsed["locals"][0]


def test_catalog_matches(mirrored: dict[str, Any]) -> None:
    assert mirrored["catalog"] == names.CATALOG


@pytest.mark.parametrize(
    ("local_key", "constant"),
    [
        ("schema_landing", "SCHEMA_LANDING"),
        ("schema_bronze", "SCHEMA_BRONZE"),
        ("schema_silver", "SCHEMA_SILVER"),
        ("schema_gold", "SCHEMA_GOLD"),
    ],
)
def test_schema_names_match(mirrored: dict[str, Any], local_key: str, constant: str) -> None:
    assert mirrored[local_key] == getattr(names, constant)


@pytest.mark.parametrize(
    ("local_key", "constant"),
    [
        ("raw_bucket", "RAW_BUCKET_DEFAULT"),
        ("serving_bucket", "SERVING_BUCKET_DEFAULT"),
        ("volume_landing", "VOLUME_LANDING"),
    ],
)
def test_storage_names_match(mirrored: dict[str, Any], local_key: str, constant: str) -> None:
    assert mirrored[local_key] == getattr(names, constant)


def test_mirror_block_contains_no_interpolation(mirrored: dict[str, Any]) -> None:
    """An interpolated mirror would compare a template string, not a value.

    ``locals { catalog = "${var.catalog}" }`` would make every assertion above
    compare against the literal text "${var.catalog}" and fail loudly — but a
    subtler interpolation could produce a string that happens to match. Forbid
    the construct outright in this block.
    """
    offenders = [k for k, v in mirrored.items() if isinstance(v, str) and "${" in v]
    assert not offenders, (
        f"locals block 0 must contain only plain literals; found interpolation in {offenders}. "
        "Move derived values to the second locals block."
    )


def test_volume_path_is_consistent_with_its_parts(mirrored: dict[str, Any]) -> None:
    """VOLUME_LANDING encodes the catalog and landing schema; they must agree.

    Catches the case where someone edits the catalog but not the volume path.
    """
    expected = f"/Volumes/{mirrored['catalog']}/{mirrored['schema_landing']}/"
    assert mirrored["volume_landing"].startswith(expected)
