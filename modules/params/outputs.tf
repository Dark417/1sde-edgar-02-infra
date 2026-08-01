output "parameter_names" {
  description = "Every published parameter name, for the §9.8 audit."
  value = sort(concat(
    keys(local.parameters),
    [for k in keys(var.oidc_role_arns) : "/edgar-lakehouse/iam/oidc_role_arn/${k}"],
  ))
}
