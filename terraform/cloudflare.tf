data "cloudflare_zone" "main" {
  filter = {
    name = var.domain
  }
}

locals {
  account_id      = data.cloudflare_zone.main.account.id
  api_hostname    = "${var.api_subdomain}.${var.domain}"
  client_hostname = var.client_hostname != "" ? var.client_hostname : var.domain
}

# --- Tunnel: api.<domain> → trivia-server, without any open port on the VM ---

resource "cloudflare_zero_trust_tunnel_cloudflared" "trivia" {
  account_id = local.account_id
  name       = "trivia"
  config_src = "cloudflare" # routes defined below, not in a file on the VM
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "trivia" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.trivia.id

  config = {
    ingress = [
      {
        hostname = local.api_hostname
        # Resolved by cloudflared, which runs inside the cluster (apps/cloudflared)
        service = "http://trivia-server.trivia.svc.cluster.local:8080"
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

# The token cloudflared uses to connect. scripts/set-secrets.sh copies it into the cluster.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "trivia" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.trivia.id
}

resource "cloudflare_dns_record" "api" {
  zone_id = data.cloudflare_zone.main.id
  name    = local.api_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.trivia.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic, required for proxied records
}

# --- Pages: the phone client, deployed by the CI of trivia-client (wrangler pages deploy) ---

resource "cloudflare_pages_project" "client" {
  account_id        = local.account_id
  name              = var.pages_project_name
  production_branch = var.pages_production_branch
}

resource "cloudflare_pages_domain" "client" {
  account_id   = local.account_id
  project_name = cloudflare_pages_project.client.name
  name         = local.client_hostname
}

resource "cloudflare_dns_record" "client" {
  zone_id = data.cloudflare_zone.main.id
  name    = local.client_hostname
  type    = "CNAME" # flattened by Cloudflare at the zone apex
  content = cloudflare_pages_project.client.subdomain
  proxied = true
  ttl     = 1
}
