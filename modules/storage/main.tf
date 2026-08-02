# ---------------------------------------------------------------------------
# Raw zone — the system of record.
#
# Immutability is the property that makes replay meaningful (design doc §8.1):
# if the raw zone can be mutated, "re-run bronze from landing" stops being a
# proof of anything. Versioning plus a deny-delete bucket policy gives that.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "raw" {
  bucket = var.raw_bucket
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AWS-0132
# SSE-S3 (AES256), not a customer-managed KMS key. This is encryption at rest
# either way; the finding is about key ownership. A CMK costs $1/month plus
# per-request charges, and two of them would roughly double this project's
# entire ~$1-3/month bill for a public-data lakehouse with no regulatory
# requirement for customer-held keys. A compliance context would change this
# answer, and nothing else about the configuration.
resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    # An empty filter applies the rule to every object. Required in provider 5.x.
    filter {}

    transition {
      days          = var.ia_transition_days
      storage_class = "STANDARD_IA"
    }

    # Versioning is on for immutability, not for keeping every revision forever.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "raw" {
  statement {
    sid    = "DenyDeleteExceptTerraformRole"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]

    resources = ["${aws_s3_bucket.raw.arn}/*"]

    # ArnNotEquals rather than NotPrincipal: NotPrincipal with Deny is notoriously
    # easy to get wrong and evaluates in ways most readers do not expect.
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [var.terraform_role_arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "raw" {
  bucket = aws_s3_bucket.raw.id
  policy = data.aws_iam_policy_document.raw.json

  # The public access block must land before a policy is attached, or the
  # BlockPublicPolicy evaluation can race on first apply.
  depends_on = [aws_s3_bucket_public_access_block.raw]
}

# ---------------------------------------------------------------------------
# Serving zone — Parquet export written by repo 4, read by repo 5.
#
# Not public. Repo 5's API reads it with credentials; making the bucket public
# would be the easy way to serve a demo and the wrong way to demonstrate access
# control.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "serving" {
  bucket = var.serving_bucket
}

resource "aws_s3_bucket_versioning" "serving" {
  bucket = aws_s3_bucket.serving.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AWS-0132
# Same reasoning as the raw bucket above: SSE-S3 rather than a customer-managed
# key, because a CMK's fixed monthly cost is out of proportion to a demo holding
# public SEC data.
resource "aws_s3_bucket_server_side_encryption_configuration" "serving" {
  bucket = aws_s3_bucket.serving.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "serving" {
  bucket                  = aws_s3_bucket.serving.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "serving" {
  bucket = aws_s3_bucket.serving.id

  rule {
    id     = "expire-old-exports"
    status = "Enabled"

    filter {}

    # The export is overwrite-only (never append), so old versions pile up fast
    # and have no value beyond a short rollback window.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

data "aws_iam_policy_document" "serving" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.serving.arn,
      "${aws_s3_bucket.serving.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = length(var.serving_reader_role_arns) > 0 ? [1] : []

    content {
      sid    = "AllowServingReaders"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.serving_reader_role_arns
      }

      actions = [
        "s3:GetObject",
        "s3:ListBucket",
      ]

      resources = [
        aws_s3_bucket.serving.arn,
        "${aws_s3_bucket.serving.arn}/*",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "serving" {
  bucket = aws_s3_bucket.serving.id
  policy = data.aws_iam_policy_document.serving.json

  depends_on = [aws_s3_bucket_public_access_block.serving]
}
