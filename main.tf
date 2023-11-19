terraform {
  required_providers {
    google = { source = "hashicorp/google" }
    ko     = { source = "ko-build/ko" }
  }
  // TODO: store state in TF
}

locals {
  apis = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "cloudscheduler.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project
  service            = each.key
  disable_on_destroy = false
}

provider "google" {
  project = var.project
  region  = var.region
}

provider "ko" {}

resource "google_artifact_registry_repository" "repo" {
  depends_on    = [google_project_service.apis]
  format        = "DOCKER"
  repository_id = "rekor-logs"
  location      = var.region
}

resource "google_storage_bucket" "bucket" {
  depends_on = [google_project_service.apis]
  name       = "${var.project}-rekor-logs"
  location   = var.region

  # Delete objects after 10 days.
  lifecycle_rule {
    condition {
      age = 10
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_bigquery_dataset" "dataset" {
  depends_on = [google_project_service.apis]
  dataset_id = "rekor_logs"
  location   = var.region
}

resource "google_bigquery_table" "table" {
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  table_id   = "rekor_logs"

  deletion_protection = false // TODO

  // TODO schemagen
  schema = <<EOF
[
  {
    "name": "time",
    "type": "TIMESTAMP",
    "description": "Log entry timestamp"
  },
  {
    "name": "log_index",
    "type": "STRING",
    "description": "Log entry index"
  }
]
EOF
}

resource "google_service_account" "dts" {
  depends_on = [google_project_service.apis]
  account_id = "rekor-logs-dts-writer"
}

resource "google_storage_bucket_iam_member" "dts" {
  depends_on = [google_service_account.dts]
  bucket     = google_storage_bucket.bucket.name
  role       = "roles/storage.objectViewer"
  member     = "serviceAccount:${google_service_account.dts.email}"
}

resource "google_bigquery_dataset_iam_member" "dts" {
  depends_on = [google_service_account.dts]
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dts.email}"
}

resource "google_bigquery_data_transfer_config" "transfer_config" {
  data_source_id         = "google_cloud_storage"
  project                = var.project
  location               = var.region
  display_name           = "Rekor logs"
  schedule               = "every 30 minutes"
  destination_dataset_id = google_bigquery_dataset.dataset.dataset_id

  params = {
    data_path_template              = "gs://${google_storage_bucket.bucket.name}/*"
    file_format                     = "JSON"
    max_bad_records                 = "10"
    destination_table_name_template = "rekor_logs"
  }
  service_account_name = google_service_account.dts.email
}

resource "ko_build" "app" {
  repo = "${var.region}-docker.pkg.dev/${var.project}/rekor-logs/app"

  importpath = "github.com/imjasonh/bq-rekor-logs"
  base_image = "cgr.dev/chainguard/static:latest-glibc"
}

resource "google_cloud_run_v2_job" "cron" {
  name     = "rekor-logs-cron"
  location = var.region

  template {
    template {
      containers {
        image = ko_build.app.image_ref
        env {
          name  = "PROJECT"
          value = var.project
        }
        env {
          name  = "BUCKET"
          value = google_storage_bucket.bucket.name
        }
        env {
          name  = "DATASET"
          value = google_bigquery_dataset.dataset.dataset_id
        }
        env {
          name  = "TABLE"
          value = google_bigquery_table.table.table_id
        }
      }
      service_account = google_service_account.cron.email
    }
  }

  lifecycle {
    ignore_changes = [
      launch_stage,
    ]
  }
}

resource "google_service_account" "cron" {
  account_id = "rekor-logs-cron"
}

resource "google_storage_bucket_iam_member" "cron" {
  bucket = google_storage_bucket.bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.cron.email}"
}

resource "google_cloud_run_v2_job_iam_member" "cron" {
  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_job.cron.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.cron.email}"
}

resource "google_cloud_scheduler_job" "cron" {
  name     = "${var.project}-rekor-logs-cron"
  schedule = "every 10 minutes"
  region   = var.region

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project}/jobs/${google_cloud_run_v2_job.cron.name}:run"

    oauth_token {
      service_account_email = google_service_account.cron.email
    }
  }
}
