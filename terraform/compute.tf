locals {
  shape = "VM.Standard.A1.Flex" # Ampere, linux/arm64 like the Raspberry Pi 5 the images were built for
}

data "oci_identity_availability_domains" "all" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = local.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "k3s" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.all.availability_domains[var.availability_domain_index].name
  display_name        = "trivia-k3s"
  shape               = local.shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "k3s"
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
    # Runs once, at the first boot: installs k3s, Argo CD and the root application
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      k3s_version               = var.k3s_version
      argocd_chart_version      = var.argocd_chart_version
      argocd_apps_chart_version = var.argocd_apps_chart_version
      gitops_repo_url           = var.gitops_repo_url
      gitops_revision           = var.gitops_revision
    }))
  }

  preserve_boot_volume = false

  lifecycle {
    # Both would recreate the VM: a newer Ubuntu image is published regularly, and cloud-init only runs at the first boot.
    # To apply a change on purpose: terraform apply -replace=oci_core_instance.k3s
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }
}
