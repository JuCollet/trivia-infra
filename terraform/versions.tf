terraform {
  required_version = ">= 1.12"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.27"
    }
  }

  # Local state for now (ignored by Git). It contains the tunnel token: keep it out of the repo.
  # Later: move it to an OCI Object Storage bucket with the "oci" backend.
}
