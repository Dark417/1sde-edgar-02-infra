variable "chat_enabled" {
  description = "Kill switch for repo 6. 'false' makes every message return the fixed kill-switch text."
  type        = string
  default     = "true"
}

variable "chat_model_main" {
  description = "Bedrock model id for the main agent. The literal string 'probe' = repo 6 probes its candidate list at startup (SSM forbids empty values)."
  type        = string
  default     = "probe"
}

variable "chat_model_cheap" {
  description = "Bedrock model id for the topic gate. The literal string 'probe' = same as main (SSM forbids empty values)."
  type        = string
  default     = "probe"
}

variable "chat_token_budget_day" {
  description = "Global daily model-token ceiling for repo 6; exhaustion returns the fixed budget text."
  type        = number
  default     = 200000
}

variable "tags" {
  description = "Standard resource tags from the root module."
  type        = map(string)
  default     = {}
}
