# --- Oracle Cloud ---

variable "oci_config_profile" {
  description = "Profile of ~/.oci/config used to authenticate."
  type        = string
  default     = "DEFAULT"
}

variable "oci_region" {
  description = "Home region of the tenancy (Always Free resources only exist there), e.g. eu-paris-1."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment holding the resources. The tenancy OCID means the root compartment."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Public key allowed to log in as the ubuntu user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_allowed_cidr" {
  description = "Only source allowed to reach port 22, e.g. your home IP followed by /32."
  type        = string
}

variable "availability_domain_index" {
  description = "Availability domain to use. Change it if the A1 shape is out of capacity in the first one."
  type        = number
  default     = 0
}

# Always Free: 4 OCPU and 24 GB of memory in total for Ampere A1, 200 GB of block storage.
variable "instance_ocpus" {
  type    = number
  default = 4
}

variable "instance_memory_gb" {
  type    = number
  default = 24
}

variable "boot_volume_gb" {
  type    = number
  default = 50
}

# --- Cloudflare ---

variable "domain" {
  description = "Zone managed by Cloudflare, e.g. example.com."
  type        = string
}

variable "api_subdomain" {
  description = "The game server is published at <api_subdomain>.<domain>."
  type        = string
  default     = "api"
}

variable "client_hostname" {
  description = "Hostname of the phone client. Empty: the zone apex, the shortest URL to type at a party."
  type        = string
  default     = ""
}

variable "pages_project_name" {
  type    = string
  default = "trivia-client"
}

variable "pages_production_branch" {
  description = "Branch of trivia-client and trivia-tv whose deployments go to production."
  type        = string
  default     = "master"
}

# --- Cluster bootstrap ---

variable "gitops_repo_url" {
  description = "Repository Argo CD synchronizes the cluster from. Public, since it holds no secret."
  type        = string
  default     = "https://github.com/JuCollet/trivia-infra.git"
}

variable "gitops_revision" {
  type    = string
  default = "master"
}

variable "k3s_version" {
  type    = string
  default = "v1.36.5+k3s1"
}

variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart (not of Argo CD itself)."
  type        = string
  default     = "10.10.3"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.6"
}

variable "api_rate_limit" {
  description = "Requests to /games allowed per IP every 10 seconds, beyond which Cloudflare blocks for 10 seconds."
  type        = number
  default     = 30
}
