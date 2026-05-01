terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "google_compute_network" "webserver_vpc" {
  name                    = "webserver-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "webserver_subnet" {
  name          = "webserver-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.webserver_vpc.id
}

# ── Firewall Rules ────────────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_http" {
  name    = "allow-http"
  network = google_compute_network.webserver_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["webserver"]
}

resource "google_compute_firewall" "allow_https" {
  name    = "allow-https"
  network = google_compute_network.webserver_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["webserver"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.webserver_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IMPORTANT: Restrict this to your IP in production.
  # Get your IP at https://whatismyipaddress.com and replace the value below.
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["webserver"]
}

# ── Static External IP (Always Free eligible) ─────────────────────────────────

resource "google_compute_address" "webserver_ip" {
  name   = "webserver-static-ip"
  region = var.region
}

# ── Compute Instance ─────────────────────────────────────────────────────────

resource "google_compute_instance" "webserver" {
  name         = "webserver"
  machine_type = "e2-micro"          # Always Free: 1 e2-micro per month (us-* regions)
  zone         = var.zone
  tags         = ["webserver"]

  boot_disk {
    initialize_params {
      # Always Free: 30 GB standard persistent disk
      image = "debian-cloud/debian-12"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.webserver_vpc.id
    subnetwork = google_compute_subnetwork.webserver_subnet.id

    access_config {
      nat_ip = google_compute_address.webserver_ip.address
    }
  }

  metadata_startup_script = file("startup.sh")

  # Required for SSH via browser / IAP (optional convenience)
  metadata = {
    enable-oslogin = "TRUE"
  }

  service_account {
    # Default compute service account with minimal scopes
    scopes = ["cloud-platform"]
  }

  # Prevent accidental deletion
  lifecycle {
    prevent_destroy = false
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "instance_name" {
  value       = google_compute_instance.webserver.name
  description = "Name of the compute instance"
}

output "external_ip" {
  value       = google_compute_address.webserver_ip.address
  description = "Static external IP — visit http://<this-ip> to see your web server"
}

output "ssh_command" {
  value       = "gcloud compute ssh webserver --zone=${var.zone} --project=${var.project_id}"
  description = "Run this command to SSH into the instance"
}
