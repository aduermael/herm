// config_overrides.go composes ephemeral CLI overrides with saved config.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

type effectiveConfigOptions struct {
	global        Config
	project       ProjectConfig
	overridesJSON string
	cacheDir      string
}

func effectiveConfig(opts effectiveConfigOptions) (Config, error) {
	cfg := mergeConfigs(mergeConfigsOptions{global: opts.global, project: opts.project})
	if strings.TrimSpace(opts.overridesJSON) != "" {
		var err error
		cfg, err = applyConfigOverrides(applyConfigOverridesOptions{base: cfg, raw: opts.overridesJSON})
		if err != nil {
			return Config{}, err
		}
	}
	cfg.RequestCacheDir = opts.cacheDir
	return cfg, nil
}

func (a *App) rebuildEffectiveConfig() {
	cfg, err := effectiveConfig(effectiveConfigOptions{global: a.globalConfig, project: a.projectConfig, overridesJSON: a.cliConfigOverrides, cacheDir: a.cliCacheDir})
	if err != nil {
		logConfigOverrideError(err)
		return
	}
	a.config = cfg
}

type applyConfigOverridesOptions struct {
	base Config
	raw  string
}

func applyConfigOverrides(opts applyConfigOverridesOptions) (Config, error) {
	raw := strings.TrimSpace(opts.raw)
	if raw == "" {
		return opts.base, nil
	}
	if !strings.HasPrefix(raw, "{") {
		return Config{}, fmt.Errorf("config overrides must be a JSON object")
	}
	cfg := opts.base
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("parse --config-overrides: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return Config{}, fmt.Errorf("parse --config-overrides: trailing JSON data")
	}
	cfg = normalizeLoadedConfig(cfg)
	return cfg, nil
}

func logConfigOverrideError(err error) {
	if err != nil {
		debugLog("config overrides ignored after validation failure: %v", err)
	}
}
