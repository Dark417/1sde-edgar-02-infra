#!/usr/bin/env bash
# Tier-1/Tier-2 leak gate (root AGENTS.md "Sensitive values").
# Runs in CI for every repo and is safe to run locally: ./scripts/secret-scan.sh
#
# Exit 1 on any hit. Scans tracked files only — untracked local files such as
# docs/LOCAL-VALUES.md, plan.txt and changelog/liquibase.properties are where
# real values are SUPPOSED to live.
set -uo pipefail

fail=0

# Obvious dummies in *.example / docs are fine and must stay readable:
# dapi000…, dapiXXXX…, <PLACEHOLDER>, "replace-me". Anything with real entropy
# is not filtered, so a genuine token in an .example file still fails.
PLACEHOLDER='dapi(0{8,}|[xX]{8,})|AKIAIOSFODNN7EXAMPLE|AKIA[X0]{16}|EXAMPLE|<[A-Z_]+>|replace[-_]me|your[-_]'

scan() { # name, extended-regex
  local name="$1" pattern="$2" hits
  # -I skips binaries; scan the committed tree, not the working dir
  hits=$(git grep -InIE "$pattern" -- . ':!*AGENTS*.md' ':!scripts/secret-scan.sh' \
         ':!docs/LOCAL-VALUES.example.md' 2>/dev/null \
         | grep -vE "$PLACEHOLDER" || true)
  if [ -n "$hits" ]; then
    echo "::error::$name"
    echo "$hits"
    fail=1
  fi
}

# --- Tier 1: real secrets. A hit means ROTATE the credential, then purge. ----
scan "Databricks PAT committed"      'dapi[0-9a-f]{24,}'
scan "AWS access key id committed"   '(A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}'
scan "Private key committed"         'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'

# --- Tier 2: environment identifiers -----------------------------------------
#
# The literals are NOT written here. Hardcoding them in a script committed to a
# public repo publishes exactly what the scan exists to keep unpublished — and
# the ':!scripts/secret-scan.sh' exclusion above meant the file could not even
# flag itself. Instead they are sourced from a gitignored file.
#
# Create scripts/tier2.env (see tier2.env.example) with KEY=VALUE lines. In CI,
# write it from repository secrets before invoking this script. If it is absent
# the Tier-2 checks are skipped with a warning rather than silently passing.
TIER2="$(dirname "$0")/tier2.env"
if [ -f "$TIER2" ]; then
  # shellcheck disable=SC1090
  . "$TIER2"
  [ -n "${AWS_ACCOUNT_ID:-}" ]     && scan "AWS account id (use <AWS_ACCOUNT_ID>)"      "\\b${AWS_ACCOUNT_ID}\\b"
  [ -n "${METASTORE_ID:-}" ]       && scan "Metastore id (use <METASTORE_ID>)"          "${METASTORE_ID}"
  [ -n "${DBX_WORKSPACE_ID:-}" ]   && scan "Workspace id (use <DBX_WORKSPACE_ID>)"      "${DBX_WORKSPACE_ID}"
  [ -n "${WAREHOUSE_ID:-}" ]       && scan "Warehouse id (use <WAREHOUSE_ID>)"          "\\b${WAREHOUSE_ID}\\b"
  [ -n "${MEMBER_ROOT_EMAIL:-}" ]  && scan "Root email (use <MEMBER_ROOT_EMAIL>)"       "${MEMBER_ROOT_EMAIL}"
else
  echo "::warning::scripts/tier2.env absent - Tier-2 identifier checks skipped."
fi

# --- Files that must never be tracked ----------------------------------------
# apply.txt joins the list: terraform apply output is dense with account ids and
# resource ARNs, and it was tracked once before this rule existed.
tracked_bad=$(git ls-files | grep -E '(^|/)(\.env|tier2\.env|.*\.tfstate.*|liquibase\.properties|LOCAL-VALUES\.md|plan\.txt|apply\.txt|tf\.plan)$' || true)
if [ -n "$tracked_bad" ]; then
  echo "::error::Files that must never be committed are tracked:"
  echo "$tracked_bad"
  fail=1
fi

if [ "$fail" -eq 0 ]; then echo "secret-scan: clean"; fi
exit "$fail"
