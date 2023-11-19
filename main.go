package main

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"log/slog"

	"cloud.google.com/go/bigquery"
	"cloud.google.com/go/storage"
	"github.com/go-openapi/strfmt"
	_ "github.com/imjasonh/gcpslog"
	"github.com/kelseyhightower/envconfig"
	rekor "github.com/sigstore/rekor/pkg/client"
	"github.com/sigstore/rekor/pkg/generated/client/entries"
	"github.com/sigstore/rekor/pkg/generated/client/index"
	"github.com/sigstore/rekor/pkg/generated/models"
)

func main() {
	ctx := context.Background()
	var env struct {
		Project string `envconfig:"PROJECT" required:"true"`
		Bucket  string `envconfig:"BUCKET" required:"true"`
		Dataset string `envconfig:"DATASET" required:"true"`
		Table   string `envconfig:"TABLE" required:"true"`
	}

	if err := envconfig.Process("", &env); err != nil {
		log.Fatal(err)
	}
	slog.Info("Starting up", "env", env)

	bq, err := bigquery.NewClient(ctx, env.Project)
	if err != nil {
		log.Fatalf("bigquery.NewClient: %v", err)
	}
	gcs, err := storage.NewClient(ctx)
	if err != nil {
		log.Fatalf("storage.NewClient: %v", err)
	}
	rekor, err := rekor.GetRekorClient("https://rekor.sigstore.dev", rekor.WithUserAgent("bq-rekor-logs"))
	if err != nil {
		log.Fatalf("rekor.GetRekorClient: %v", err)
	}

	// Find highwater mark in BQ
	// TODO: This should be the latest record, not the last time we wrote a record, which could be after the latest record due to DTS latency.

	datasetID := fmt.Sprintf("`%s.%s.%s`", env.Project, env.Dataset, env.Table)
	it, err := bq.Query("SELECT MAX(timestamp) FROM " + datasetID).Read(ctx)
	if err != nil {
		log.Fatalf("bq.Query: %v", err)
	}
	var row struct{ Timestamp int64 }
	if err := it.Next(&row); err != nil {
		log.Fatalf("it.Next: %v", err)
	}
	highwater := row.Timestamp
	slog.Info("Found highwater mark", "highwater", highwater)

	// Query Rekor logs since highwater mark.
	resp, err := rekor.Index.SearchIndex(&index.SearchIndexParams{
		Context: ctx,
		Query: &models.SearchIndex{
			Email: strfmt.Email("jason@chainguard.dev"),
		},
	})
	if err != nil {
		log.Fatalf("rekor.Index.SearchIndex: %v", err)
	}
	log.Printf("found %d entries", len(resp.Payload))
	obj := fmt.Sprintf("rekor-%d.json", highwater)
	w := gcs.Bucket(env.Bucket).Object(obj).NewWriter(ctx)
	defer w.Close()
	for _, uuid := range resp.Payload[0:10] { // TODO remove
		eresp, err := rekor.Entries.GetLogEntryByUUID(&entries.GetLogEntryByUUIDParams{
			Context:   ctx,
			EntryUUID: uuid,
		})
		if err != nil {
			log.Fatalf("rekor.Entries.GetLogEntryByUUID(%q): %v", uuid, err)
		}

		// Skip entries that are older than the highwater mark.
		if eresp.Payload[uuid].IntegratedTime == nil {
			continue
		}
		if *eresp.Payload[uuid].IntegratedTime < highwater {
			continue
		}

		slog.Info("Found entry",
			"uuid", uuid,
			"integratedTime", eresp.Payload[uuid].IntegratedTime,
			"logID", eresp.Payload[uuid].LogID)
		b, err := base64.StdEncoding.DecodeString(eresp.Payload[uuid].Body.(string))
		if err != nil {
			log.Fatalf("base64.StdEncoding.DecodeString: %v", err)
		}
		var entry struct {
			Spec struct {
				Signature struct {
					PublicKey struct {
						Content []byte
					}
				}
			}
		}
		if err := json.Unmarshal(b, &entry); err != nil {
			log.Fatalf("json.Unmarshal: %v", err)
		}

		block, _ := pem.Decode(entry.Spec.Signature.PublicKey.Content)
		if block == nil {
			slog.ErrorContext(ctx, "pem.Decode: got nil")
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			slog.ErrorContext(ctx, fmt.Sprintf("x509.ParseCertificate: %v", err))
			continue
		}
		slog.Info("Found certificate", "emails", cert.EmailAddresses)
		if err := json.NewEncoder(w).Encode(cert); err != nil {
			slog.ErrorContext(ctx, fmt.Sprintf("json.NewEncoder.Encode: %v", err))
			continue
		}
	}
	slog.Info(fmt.Sprintf("writing GCS object: %s", obj))
}
