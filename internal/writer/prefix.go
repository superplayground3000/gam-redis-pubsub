// $LAB/writer/prefix.go
package writer

import (
	"fmt"
	"regexp"
	"strings"
)

// keyPrefixToken is a single legal NATS subject token: the injected prefix becomes
// a subject segment (kv.cdc.<prefix>.<op>) downstream, so it must not contain '.',
// whitespace, or the wildcards '*'/'>'.
var keyPrefixToken = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// parseKeyPrefixes parses the KEY_PREFIXES env value (comma-separated). Empty or
// whitespace-only input returns nil so writer behavior is byte-for-byte unchanged
// from before this feature existed. Each token is trimmed and validated; an
// illegal or empty token is a fatal error (fail-loud at startup), never silently
// dropped, because a bad prefix would route messages to a subject nobody consumes.
func parseKeyPrefixes(s string) ([]string, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if !keyPrefixToken.MatchString(p) {
			return nil, fmt.Errorf("invalid KEY_PREFIXES token %q: each prefix must match [A-Za-z0-9_-]+", p)
		}
		out = append(out, p)
	}
	return out, nil
}

// applyKeyPrefix prepends the entity's prefix to key when prefixes is non-empty.
// With no prefixes the key is returned unchanged. The prefix is chosen by entity
// id (prefixes[id % len]) so EVERY op on the same entity — including a
// standby->active rename whose two keys share the id — lands on the same prefix,
// hence the same subject and consumer. That is the correctness premise for
// splitting by prefix: it preserves per-entity ordering. The original key
// (including its {entity:id} hash tag) is left intact after the "<prefix>:" cut.
func applyKeyPrefix(prefixes []string, id int64, key string) string {
	if len(prefixes) == 0 {
		return key
	}
	return prefixes[id%int64(len(prefixes))] + ":" + key
}
