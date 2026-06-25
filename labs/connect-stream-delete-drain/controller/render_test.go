package main

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRenderPipeline(t *testing.T) {
	tmpl := "threads: __THREADS__\nduration: __SLEEP_MS__ms\n"
	out := RenderPipeline(tmpl, 200, 4)
	require.Equal(t, "threads: 4\nduration: 200ms\n", out)
	require.False(t, strings.Contains(out, "__"))
}
