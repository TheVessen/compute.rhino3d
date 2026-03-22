# ============================================================
# Rhino.Compute on GCP — Terraform Configuration
# ============================================================
#
# Usage:
#   1. Update variables in terraform.tfvars
#   2. terraform init
#   3. terraform apply
#   4. terraform destroy  (to tear it all down)
#
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# ============================================================
# Provider
# ============================================================
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ============================================================
# Variables
# ============================================================
variable "project_id" {
  description = "Your GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west6" # Zurich — closest to Switzerland
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west6-a"
}

variable "machine_type" {
  description = "VM machine type"
  type        = string
  default     = "e2-standard-4" # 4 vCPU, 16 GB RAM
}

variable "rhino_token" {
  description = "Rhino Core-Hour Billing token"
  type        = string
  sensitive   = true
}

variable "repo_url" {
  description = "Git repo URL for Rhino.Compute"
  type        = string
  default     = "https://github.com/mcneel/compute.rhino3d.git"
}

variable "repo_branch" {
  description = "Git branch to checkout"
  type        = string
  default     = "x9"
}

# ============================================================
# Static IP
# ============================================================
resource "google_compute_address" "rhino_compute_ip" {
  name   = "rhino-compute-ip"
  region = var.region
}

# ============================================================
# Firewall — allow port 6500 from anywhere
# ============================================================
resource "google_compute_firewall" "allow_rhino_compute" {
  name    = "allow-rhino-compute"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["6500"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["rhino-compute"]
}

# ============================================================
# Firewall — allow SSH
# ============================================================
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh-rhino-compute"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["rhino-compute"]
}

# ============================================================
# VM Instance
# ============================================================
resource "google_compute_instance" "rhino_compute" {
  name         = "rhino-compute-server"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["rhino-compute"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30 # GB
      type  = "pd-ssd"
    }
  }

  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.rhino_compute_ip.address
    }
  }

  # Startup script — runs automatically on first boot
  metadata_startup_script = templatefile("${path.module}/startup.sh", {
    rhino_token = var.rhino_token
    repo_url    = var.repo_url
    repo_branch = var.repo_branch
  })

  # Allow the VM to be stopped and restarted
  allow_stopping_for_update = true

  service_account {
    scopes = ["cloud-platform"]
  }
}

# ============================================================
# Outputs
# ============================================================
output "server_ip" {
  description = "Public IP of the Rhino.Compute server"
  value       = google_compute_address.rhino_compute_ip.address
}

output "server_url" {
  description = "URL to connect to Rhino.Compute"
  value       = "http://${google_compute_address.rhino_compute_ip.address}:6500"
}

output "ssh_command" {
  description = "SSH into the server"
  value       = "gcloud compute ssh rhino-compute-server --zone=${var.zone} --project=${var.project_id}"
}
