package coderd

import (
	"net/http"
	"net/url"
	"strings"
)

// LatencyCheck is an endpoint for the web ui to measure latency with.
// allowAll allows any Origin to get timing information. The allowAll should
// only be set in dev modes.
//
//nolint:revive
func LatencyCheck(allowAll bool, allowedOrigins ...*url.URL) http.HandlerFunc {
	allowed := make([]string, 0, len(allowedOrigins))
	for _, origin := range allowedOrigins {
		// Allow the origin without a path
		tmp := *origin
		tmp.Path = ""
		allowed = append(allowed, strings.TrimSuffix(origin.String(), "/"))
	}
	if allowAll {
		allowed = append(allowed, "*")
	}
	origins := strings.Join(allowed, ",")
	return func(rw http.ResponseWriter, r *http.Request) {
		// Allowing timing information to be shared. This allows the browser
		// to exclude TLS handshake timing.
		rw.Header().Set("Timing-Allow-Origin", origins)
		// Always allow all CORs on this route.
		rw.Header().Set("Access-Control-Allow-Origin", "*")
		rw.Header().Set("Access-Control-Allow-Headers", "*")
		rw.Header().Set("Access-Control-Allow-Credentials", "false")
		// Always allow the calling method
		rw.Header().Set("Access-Control-Allow-Methods", r.Method)
		rw.WriteHeader(http.StatusOK)
		_, _ = rw.Write([]byte("OK"))
	}
}
