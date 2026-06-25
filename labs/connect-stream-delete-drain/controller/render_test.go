package main

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRenderPipeline(t *testing.T) {
	tmpl := "threads: __THREADS__\nduration: __SLEEP_MS__ms\nmax_ack_pending: __MAX_ACK_PENDING__\n"
	out := RenderPipeline(tmpl, 200, 4, 1000)
	require.Equal(t, "threads: 4\nduration: 200ms\nmax_ack_pending: 1000\n", out)
	require.False(t, strings.Contains(out, "__"))
}
