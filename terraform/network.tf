# A public subnet, but the only open port is SSH from your IP:
# players reach the server through the Cloudflare tunnel, an outbound connection from the cluster.

resource "oci_core_vcn" "trivia" {
  compartment_id = var.compartment_ocid
  display_name   = "trivia"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "trivia"
}

# Outbound access: image pulls, Claude API, Cloudflare tunnel
resource "oci_core_internet_gateway" "trivia" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.trivia.id
  display_name   = "trivia"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.trivia.id
  display_name   = "public"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.trivia.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.trivia.id
  display_name   = "public"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    description = "SSH"
    source      = var.ssh_allowed_cidr
    protocol    = "6" # TCP
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Path MTU discovery, as in the default security list
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1" # ICMP
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.trivia.id
  display_name      = "public"
  cidr_block        = "10.0.1.0/24"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
}
