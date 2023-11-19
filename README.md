# bqrekor

Scraping Rekor into a BigQuery dataset

_WORK IN PROGRESS_

## Setup

```
terraform init
terraform apply
```

This will prompt for a Google Cloud project ID and region.

It will create:

* A BigQuery dataset and table called `rekor_logs`
* A Cloud Run Job that scrapes the Rekor API and write the results into a GCS object as JSON
* A Cloud Scheduler config to run the Cloud Run Job every 10 minutes
* A BigQuery Data Transfer config to load the GCS object into the BigQuery table on a schedule

The result is an automatically updating BigQuery table containing Rekor entries seen by the app.
