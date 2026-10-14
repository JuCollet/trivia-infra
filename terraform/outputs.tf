output "public_ip" {
  value = oci_core_instance.k3s.public_ip
}

output "ssh" {
  value = "ssh ubuntu@${oci_core_instance.k3s.public_ip}"
}

output "api_url" {
  description = "VITE_API_URL of trivia-client and EXPO_PUBLIC_API_URL of trivia-tv."
  value       = "https://${local.api_hostname}"
}

output "client_url" {
  value = "https://${local.client_hostname}"
}

output "tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.trivia.token
  sensitive = true
}
