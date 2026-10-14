# Credentials come from ~/.oci/config (API key created in the OCI console), never from this repo.
provider "oci" {
  config_file_profile = var.oci_config_profile
  region              = var.oci_region
}

# Reads the API token from the CLOUDFLARE_API_TOKEN environment variable.
provider "cloudflare" {}
