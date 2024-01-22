resource "google_service_account" "proxy" {
  project    = var.project_id
  account_id = "squid-proxy"
}

resource "google_project_iam_member" "proxy_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.proxy.email}"
}

resource "google_project_iam_member" "proxy_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.proxy.email}"
}

resource "google_compute_instance_template" "proxy" {
  project     = var.project_id
  region      = "europe-west1"
  name_prefix = "squid-proxy-"

  machine_type = "e2-medium"
  metadata_startup_script = templatefile("${path.module}/resources/squid_proxy_startup_script.sh.tftpl", {
    load_balancer_ip = google_compute_address.proxy.address
  })

  disk {
    source_image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-ssd"

    auto_delete = true
  }

  can_ip_forward = false

  # NOTE: Order of interfaces matter. DNS et al is bound to primary NIC.
  network_interface {
    subnetwork_project = var.project_id
    subnetwork         = google_compute_subnetwork.destination_vpc_nat.self_link
  }

  network_interface {
    subnetwork_project = var.project_id
    subnetwork         = google_compute_subnetwork.source_vpc_proxy.self_link
  }

  service_account {
    email  = google_service_account.proxy.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "proxy" {
  project = var.project_id
  region  = "europe-west1"
  name    = "squid-proxy-mig"

  base_instance_name = "squid-proxy"

  version {
    instance_template = google_compute_instance_template.proxy.id
  }

  named_port {
    name = "proxy"
    port = 3128
  }

  update_policy {
    type            = "PROACTIVE"
    minimal_action  = "REPLACE"
    max_surge_fixed = 5
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.proxy_probe.id
    initial_delay_sec = 60
  }
}

# Allow health checks from instance group manager
resource "google_compute_firewall" "destination_vpc_gfe_proxy_ingress" {
  project     = var.project_id
  network     = google_compute_network.destination_vpc.id
  name        = "${google_compute_network.destination_vpc.name}-gfe-proxy-ingress"
  description = "Accept Google Front End (GFE) proxy traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]
  target_service_accounts = [google_service_account.proxy.email]

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }
}

resource "google_compute_health_check" "proxy_probe" {
  project = var.project_id
  name    = "squid-proxy-probe"

  timeout_sec        = 5
  check_interval_sec = 10

  tcp_health_check {
    port         = 3128
    proxy_header = "PROXY_V1"
  }
}

resource "google_compute_region_autoscaler" "proxy" {
  project = var.project_id
  region  = "europe-west1"
  name    = "squid-proxy-autoscaler"

  target = google_compute_region_instance_group_manager.proxy.id

  autoscaling_policy {
    min_replicas    = 1
    max_replicas    = 3
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}

resource "google_compute_address" "proxy" {
  project      = var.project_id
  region       = "europe-west1"
  name         = "squid-proxy"
  subnetwork   = google_compute_subnetwork.source_vpc_proxy.id
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "proxy" {
  project = var.project_id
  region  = "europe-west1"
  name    = "squid-proxy"

  ip_address            = google_compute_address.proxy.address
  ip_protocol           = "TCP"
  ports                 = ["3128"]
  load_balancing_scheme = "INTERNAL"

  allow_global_access = false

  network    = google_compute_network.source_vpc.id
  subnetwork = google_compute_subnetwork.source_vpc_proxy.id

  backend_service = google_compute_region_backend_service.proxy.id
}


resource "google_compute_region_backend_service" "proxy" {
  project = var.project_id
  region  = "europe-west1"
  name    = "squid-proxy"

  protocol                        = "TCP"
  load_balancing_scheme           = "INTERNAL"
  network                         = google_compute_network.source_vpc.id
  connection_draining_timeout_sec = 10

  health_checks = [google_compute_health_check.proxy_probe.id]

  backend {
    group = google_compute_region_instance_group_manager.proxy.instance_group
  }
}

# Allow health checks from load balancer on source VPC
resource "google_compute_firewall" "source_vpc_gfe_proxy_ingress" {
  project     = var.project_id
  network     = google_compute_network.source_vpc.id
  name        = "${google_compute_network.source_vpc.name}-gfe-proxy-ingress"
  description = "Accept Google Front End (GFE) proxy traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]
  target_service_accounts = [google_service_account.proxy.email]

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }
}

# Allow clients to access proxy port
resource "google_compute_firewall" "source_vpc_allow_proxy_access" {
  project     = var.project_id
  network     = google_compute_network.source_vpc.id
  name        = "${google_compute_network.source_vpc.name}-client-proxy-ingress"
  description = "Accept source VPC proxy traffic"

  priority  = 4000
  direction = "INGRESS"
  source_ranges = [
    google_compute_subnetwork.source_vpc_clients.ip_cidr_range,
  ]
  target_service_accounts = [google_service_account.proxy.email]

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }
}

# Configure a friendly DNS name: proxy.xebia
resource "google_dns_record_set" "source_vpc_xebia" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.source_vpc_xebia.name
  name         = "proxy.xebia."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.proxy.address]
}