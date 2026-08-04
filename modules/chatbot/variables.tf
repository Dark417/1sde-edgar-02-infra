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

variable "deploy_chatbot" {
  description = "Create the always-on EC2 host for repo 6. Costs ~$10.42/month; false by default so the config-only footprint stays free."
  type        = bool
  default     = false
}

variable "chatbot_instance_type" {
  description = "t4g.micro (1 GB) is the floor: the app measures 424 MB RSS with data loaded, so a 512 MB host swaps or OOMs."
  type        = string
  default     = "t4g.micro"
}

variable "chatbot_allowed_cidrs" {
  description = "CIDRs allowed to reach the UI. Default is the public internet because the point is a shareable demo link; narrow it to your own /32 while testing."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "serving_bucket" {
  description = "Bucket holding the exported gold Parquet the app reads at boot."
  type        = string
  default     = "edgar-lake-serving"
}

variable "chatbot_repo_url" {
  description = "Public repo the host clones at boot. Public on purpose: no deploy key on the box."
  type        = string
  default     = "https://github.com/Dark417/1sde-edgar-06-chatbot.git"
}

variable "vpc_id" {
  description = "VPC for the chatbot security group. Empty means the account default VPC."
  type        = string
  default     = ""
}
