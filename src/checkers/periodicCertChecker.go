package checkers

import (
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/bmatcuk/doublestar/v4"
	"github.com/joe-elliott/cert-exporter/src/exporters"
	"github.com/joe-elliott/cert-exporter/src/metrics"
)

type certGlob struct {
	searchRoot string
	pattern    string
}

func newCertGlob(s string) *certGlob {
	base, pattern := doublestar.SplitPattern(s)
	glob := &certGlob{
		searchRoot: base,
		pattern:    pattern,
	}

	return glob
}

// Join concatenates the provided path with the glob search root.
func (g *certGlob) Join(p string) string {
	return filepath.Join(g.searchRoot, p)
}

// Apply calls [doublestar.Glob] using the configured search root
// and filter pattern and returns file paths relative to the search
// root. Use [Join] to receive the file path which closely resembles
// the original search input.
func (g *certGlob) Apply() ([]string, error) {
	return doublestar.Glob(
		os.DirFS(g.searchRoot),
		g.pattern,
		doublestar.WithFilesOnly(),
	)
}

// PeriodicCertChecker is an object designed to check for files on disk at a regular interval
type PeriodicCertChecker struct {
	period           time.Duration
	includeCertGlobs []*certGlob
	excludeCertGlobs []*certGlob
	nodeName         string
	exporter         exporters.Exporter
	// lastDiscovered is this checker's previous contribution to the shared
	// metrics.Discovered gauge. Each checker adjusts the gauge by delta so
	// concurrent cert and kubeconfig checkers accumulate instead of overwrite.
	lastDiscovered float64
}

// NewCertChecker is a factory method that returns a new PeriodicCertChecker
func NewCertChecker(period time.Duration, includeCertGlobs, excludeCertGlobs []string, nodeName string, e exporters.Exporter) *PeriodicCertChecker {
	includes := make([]*certGlob, 0, len(includeCertGlobs))
	for _, i := range includeCertGlobs {
		g := newCertGlob(i)
		includes = append(includes, g)
	}

	excludes := make([]*certGlob, 0, len(excludeCertGlobs))
	for _, e := range excludeCertGlobs {
		g := newCertGlob(e)
		excludes = append(excludes, g)
	}

	return &PeriodicCertChecker{
		period:           period,
		includeCertGlobs: includes,
		excludeCertGlobs: excludes,
		nodeName:         nodeName,
		exporter:         e,
	}
}

// StartChecking starts the periodic file check.  Most likely you want to run this as an independent go routine.
func (p *PeriodicCertChecker) StartChecking() {
	periodChannel := time.Tick(p.period)

	for {
		p.checkOnce()
		<-periodChannel
	}
}

// checkOnce performs a single scan-and-export cycle (used by tests without leaking a goroutine).
func (p *PeriodicCertChecker) checkOnce() {
	slog.Info("Begin periodic check")

	p.exporter.ResetMetrics()

	for _, match := range p.getMatches() {
		slog.Info("Publishing node metrics", "nodeName", p.nodeName, "match", match)

		err := p.exporter.ExportMetrics(match, p.nodeName)
		if err != nil {
			metrics.ErrorTotal.Inc()
			slog.Error("Error exporting metrics", "match", match, "error", err)
		}
	}
}

func (p *PeriodicCertChecker) getMatches() []string {
	set := map[string]bool{}
	for _, includeGlob := range p.includeCertGlobs {
		matches, err := includeGlob.Apply()
		if err != nil {
			metrics.ErrorTotal.Inc()
			slog.Error("Glob failed", "glob", includeGlob, "error", err)
			continue
		}
		for _, match := range matches {
			match = includeGlob.Join(match)
			set[match] = true
		}
	}

	for _, excludeGlob := range p.excludeCertGlobs {
		matches, err := excludeGlob.Apply()
		if err != nil {
			metrics.ErrorTotal.Inc()
			slog.Error("Glob failed", "glob", excludeGlob, "error", err)
			continue
		}
		for _, match := range matches {
			match = excludeGlob.Join(match)
			delete(set, match)
		}

		if len(set) == 0 {
			slog.Info("No certificate files matched the provided globs")
		}
	}

	// Adjust the shared gauge by this checker's contribution only. Using Set
	// here would race with other PeriodicCertChecker goroutines (e.g. cert +
	// kubeconfig) and leave the metric at whichever finished last.
	n := float64(len(set))
	metrics.Discovered.Add(n - p.lastDiscovered)
	p.lastDiscovered = n

	res := make([]string, len(set))
	i := 0
	for k := range set {
		res[i] = k
		i++
	}
	return res
}
