// website_demo_assets_test.go verifies the marketing demo media and website
// hero markup stay consistent: new docs/img demo assets exist, HTML paths
// resolve to those files (no deleted demo-cropped.*), README autoplay GIF
// path matches a real file, and the window chrome (titlebar, rainbow glow,
// rounded corners) still wraps the media.
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebsiteDemoAssetsExist(t *testing.T) {
	root := repoRoot(t)
	required := []string{
		"docs/img/demo.mp4",
		"docs/img/demo.gif",
		"img/demo.mp4",
		"img/demo.gif",
	}
	for _, rel := range required {
		path := filepath.Join(root, rel)
		st, err := os.Stat(path)
		if err != nil {
			t.Errorf("required demo asset missing: %s (%v)", rel, err)
			continue
		}
		if st.IsDir() {
			t.Errorf("required demo asset is a directory: %s", rel)
		}
		if st.Size() == 0 {
			t.Errorf("required demo asset is empty: %s", rel)
		}
	}

	// Deleted cropped intermediates must not reappear as the site source of truth.
	for _, rel := range []string{
		"docs/img/demo-cropped.mp4",
		"docs/img/demo-cropped.gif",
	} {
		if _, err := os.Stat(filepath.Join(root, rel)); err == nil {
			t.Errorf("obsolete cropped asset should not exist: %s", rel)
		}
	}
}

func TestWebsiteDemoMarkupUsesNewAssetsAndChrome(t *testing.T) {
	root := repoRoot(t)
	html := readRepoFile(t, root, "docs/index.html")

	if strings.Contains(html, "demo-cropped") {
		t.Error("docs/index.html still references deleted demo-cropped assets")
	}

	// Hero video: poster + source + img fallback must use non-cropped paths.
	needles := []string{
		`poster="img/demo.gif"`,
		`src="img/demo.mp4"`,
		`src="img/demo.gif"`,
		`type="video/mp4"`,
	}
	for _, n := range needles {
		if !strings.Contains(html, n) {
			t.Errorf("docs/index.html missing expected demo markup %q", n)
		}
	}

	// Window chrome: titlebar, rainbow border, rounded frame must remain.
	chrome := []string{
		`class="demo-titlebar"`,
		`class="demo-glow"`,
		`class="demo-container"`,
		`class="demo-dot"`,
		`demo-titlebar-text`,
		`conic-gradient`,
		`spin-border`,
		`overflow: hidden`,
	}
	for _, n := range chrome {
		if !strings.Contains(html, n) {
			t.Errorf("docs/index.html missing demo chrome %q", n)
		}
	}

	// DOM order: glow wraps container which contains titlebar then video.
	glowIdx := strings.Index(html, `class="demo-glow"`)
	containerIdx := strings.Index(html, `class="demo-container"`)
	titlebarIdx := strings.Index(html, `class="demo-titlebar"`)
	videoIdx := strings.Index(html, `<video autoplay loop muted playsinline`)
	if glowIdx < 0 || containerIdx < 0 || titlebarIdx < 0 || videoIdx < 0 {
		t.Fatal("demo DOM structure incomplete")
	}
	if !(glowIdx < containerIdx && containerIdx < titlebarIdx && titlebarIdx < videoIdx) {
		t.Errorf("demo DOM order wrong: glow=%d container=%d titlebar=%d video=%d",
			glowIdx, containerIdx, titlebarIdx, videoIdx)
	}
}

func TestREADMEDemoGIFPathResolves(t *testing.T) {
	root := repoRoot(t)
	readme := readRepoFile(t, root, "README.md")
	if !strings.Contains(readme, "img/demo.gif") {
		t.Error("README.md should reference img/demo.gif for GitHub autoplay")
	}
	if _, err := os.Stat(filepath.Join(root, "img/demo.gif")); err != nil {
		t.Errorf("README demo GIF missing at img/demo.gif: %v", err)
	}
}
