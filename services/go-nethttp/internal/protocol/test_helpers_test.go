package protocol

import (
	"testing"

	json "github.com/goccy/go-json"
)

func DecodeObjectForTest(t *testing.T, payload []byte) map[string]any {
	t.Helper()

	var object map[string]any
	if err := json.Unmarshal(payload, &object); err != nil {
		t.Fatalf("decode object: %v", err)
	}
	return object
}
