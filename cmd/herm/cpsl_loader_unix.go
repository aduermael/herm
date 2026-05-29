//go:build darwin || linux

package main

import (
	"fmt"
	"strings"
	"unsafe"

	"github.com/ebitengine/purego"
)

type cpslNativeLibrary struct {
	handle uintptr

	abiVersionFn   func() uint32
	metadataJSONFn func() unsafe.Pointer
	sessionNewFn   func(string) unsafe.Pointer
	sessionFreeFn  func(unsafe.Pointer)
	evalFn         func(unsafe.Pointer, string) unsafe.Pointer
	stringFreeFn   func(unsafe.Pointer)
	lastErrorFn    func() unsafe.Pointer
}

func openCPSLNativeLibrary(path string) (*cpslNativeLibrary, error) {
	handle, err := purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, fmt.Errorf("load CPSL library: %w", err)
	}
	lib := &cpslNativeLibrary{handle: handle}
	ok := false
	defer func() {
		if !ok {
			_ = lib.close()
		}
	}()

	if err := lib.registerFunc(&lib.abiVersionFn, "cpsl_abi_version"); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(&lib.metadataJSONFn, "cpsl_backend_metadata_json"); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(&lib.sessionNewFn, "cpsl_session_new"); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(&lib.sessionFreeFn, "cpsl_session_free"); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(&lib.evalFn, "cpsl_eval"); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(&lib.stringFreeFn, "cpsl_string_free"); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(&lib.lastErrorFn, "cpsl_last_error"); err != nil {
		return nil, err
	}

	ok = true
	return lib, nil
}

func (l *cpslNativeLibrary) registerFunc(target any, name string) error {
	symbol, err := purego.Dlsym(l.handle, name)
	if err != nil {
		return fmt.Errorf("resolve CPSL symbol %s: %w", name, err)
	}
	if symbol == 0 {
		return fmt.Errorf("resolve CPSL symbol %s: missing symbol", name)
	}
	purego.RegisterFunc(target, symbol)
	return nil
}

func (l *cpslNativeLibrary) abiVersion() (uint32, error) {
	return l.abiVersionFn(), nil
}

func (l *cpslNativeLibrary) backendMetadataJSON() (string, error) {
	value := l.metadataJSONFn()
	if value == nil {
		return "", fmt.Errorf("CPSL metadata failed: %s", l.lastError())
	}
	defer l.stringFreeFn(value)
	return stringFromC(value), nil
}

func (l *cpslNativeLibrary) sessionNew(configJSON string) (cpslSession, error) {
	if err := validateFFIString(configJSON); err != nil {
		return 0, err
	}
	session := l.sessionNewFn(configJSON)
	if session == nil {
		return 0, fmt.Errorf("CPSL session creation failed: %s", l.lastError())
	}
	return cpslSession(uintptr(session)), nil
}

func (l *cpslNativeLibrary) sessionFree(session cpslSession) {
	l.sessionFreeFn(unsafe.Pointer(uintptr(session)))
}

func (l *cpslNativeLibrary) eval(session cpslSession, requestJSON string) (string, error) {
	if err := validateFFIString(requestJSON); err != nil {
		return "", err
	}
	value := l.evalFn(unsafe.Pointer(uintptr(session)), requestJSON)
	if value == nil {
		return "", fmt.Errorf("CPSL eval failed: %s", l.lastError())
	}
	defer l.stringFreeFn(value)
	return stringFromC(value), nil
}

func (l *cpslNativeLibrary) lastError() string {
	return stringFromC(l.lastErrorFn())
}

func (l *cpslNativeLibrary) close() error {
	if l == nil || l.handle == 0 {
		return nil
	}
	err := purego.Dlclose(l.handle)
	l.handle = 0
	return err
}

func validateFFIString(value string) error {
	if strings.Contains(value, "\x00") {
		return fmt.Errorf("CPSL FFI string contains an embedded NUL byte")
	}
	return nil
}
