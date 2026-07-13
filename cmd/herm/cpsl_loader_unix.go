//go:build darwin || linux

// cpsl_loader_unix.go loads CPSL shared libraries on Darwin and Linux through
// purego and exposes the common native-library interface.
package main

import (
	"fmt"
	"runtime"
	"strings"
	"unsafe"

	"github.com/ebitengine/purego"
)

type cpslSession unsafe.Pointer

type cpslNativeLibrary struct {
	handle uintptr

	abiVersionFn                    func() uint32
	metadataJSONFn                  func() unsafe.Pointer
	sessionNewFn                    func(string) unsafe.Pointer
	sessionNewWithHostCallbacksV3Fn func(string, unsafe.Pointer, unsafe.Pointer, unsafe.Pointer, unsafe.Pointer, unsafe.Pointer) unsafe.Pointer
	visionRespondFn                 func(unsafe.Pointer, unsafe.Pointer, uintptr, uint8)
	sessionFreeFn                   func(unsafe.Pointer)
	evalFn                          func(unsafe.Pointer, string) unsafe.Pointer
	stringFreeFn                    func(unsafe.Pointer)
	lastErrorFn                     func() unsafe.Pointer
	visionCallback                  func(uintptr, uintptr, uintptr, uintptr, uintptr)
}

type cpslVisionInputFFI struct {
	data      unsafe.Pointer
	dataLen   uintptr
	filename  unsafe.Pointer
	mediaType unsafe.Pointer
}

type cpslVisionCallbacksFFI struct {
	userData     unsafe.Pointer
	handle       uintptr
	userDataFree uintptr
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

	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.abiVersionFn, name: "cpsl_abi_version"}); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.metadataJSONFn, name: "cpsl_backend_metadata_json"}); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.sessionNewFn, name: "cpsl_session_new"}); err != nil {
		return nil, err
	}
	_ = lib.registerOptionalFunc(cpslRegisterFuncOptions{target: &lib.sessionNewWithHostCallbacksV3Fn, name: "cpsl_session_new_with_host_callbacks_v3"})
	_ = lib.registerOptionalFunc(cpslRegisterFuncOptions{target: &lib.visionRespondFn, name: "cpsl_vision_respond"})
	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.sessionFreeFn, name: "cpsl_session_free"}); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.evalFn, name: "cpsl_eval"}); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.stringFreeFn, name: "cpsl_string_free"}); err != nil {
		return nil, err
	}
	if err := lib.registerFunc(cpslRegisterFuncOptions{target: &lib.lastErrorFn, name: "cpsl_last_error"}); err != nil {
		return nil, err
	}

	ok = true
	return lib, nil
}

type cpslRegisterFuncOptions struct {
	target any
	name   string
}

func (l *cpslNativeLibrary) registerFunc(opts cpslRegisterFuncOptions) error {
	symbol, err := purego.Dlsym(l.handle, opts.name)
	if err != nil {
		return fmt.Errorf("resolve CPSL symbol %s: %w", opts.name, err)
	}
	if symbol == 0 {
		return fmt.Errorf("resolve CPSL symbol %s: missing symbol", opts.name)
	}
	purego.RegisterFunc(opts.target, symbol)
	return nil
}

func (l *cpslNativeLibrary) registerOptionalFunc(opts cpslRegisterFuncOptions) error {
	symbol, err := purego.Dlsym(l.handle, opts.name)
	if err != nil || symbol == 0 {
		return err
	}
	purego.RegisterFunc(opts.target, symbol)
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
		return nil, err
	}
	session := l.sessionNewFn(configJSON)
	if session == nil {
		return nil, fmt.Errorf("CPSL session creation failed: %s", l.lastError())
	}
	return cpslSession(session), nil
}

func (l *cpslNativeLibrary) sessionNewWithVision(configJSON string, handler cpslVisionHandler) (cpslSession, error) {
	if handler == nil || l.sessionNewWithHostCallbacksV3Fn == nil || l.visionRespondFn == nil {
		return l.sessionNew(configJSON)
	}
	if err := validateFFIString(configJSON); err != nil {
		return nil, err
	}

	callback := func(_ uintptr, inputsPointer uintptr, inputCount uintptr, queryPointer uintptr, responseContext uintptr) {
		var result string
		var callbackErr error
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					callbackErr = fmt.Errorf("vision callback panicked: %v", recovered)
				}
			}()
			ffiInputs := unsafe.Slice((*cpslVisionInputFFI)(unsafe.Pointer(inputsPointer)), inputCount)
			inputs := make([]cpslVisionInput, 0, len(ffiInputs))
			for _, input := range ffiInputs {
				data := append([]byte(nil), unsafe.Slice((*byte)(input.data), input.dataLen)...)
				inputs = append(inputs, cpslVisionInput{
					Data:      data,
					Filename:  stringFromC(input.filename),
					MediaType: stringFromC(input.mediaType),
				})
			}
			result, callbackErr = handler(inputs, stringFromC(unsafe.Pointer(queryPointer)))
		}()
		if callbackErr != nil {
			result = callbackErr.Error()
		}
		bytes := []byte(result)
		var data unsafe.Pointer
		if len(bytes) > 0 {
			data = unsafe.Pointer(&bytes[0])
		}
		l.visionRespondFn(unsafe.Pointer(responseContext), data, uintptr(len(bytes)), boolByte(callbackErr != nil))
		runtime.KeepAlive(bytes)
	}
	l.visionCallback = callback
	callbacks := cpslVisionCallbacksFFI{handle: purego.NewCallback(callback)}
	session := l.sessionNewWithHostCallbacksV3Fn(
		configJSON,
		nil,
		nil,
		nil,
		nil,
		unsafe.Pointer(&callbacks),
	)
	runtime.KeepAlive(callbacks)
	if session == nil {
		return nil, fmt.Errorf("CPSL session creation failed: %s", l.lastError())
	}
	return cpslSession(session), nil
}

func boolByte(value bool) uint8 {
	if value {
		return 1
	}
	return 0
}

func (l *cpslNativeLibrary) sessionFree(session cpslSession) {
	l.sessionFreeFn(unsafe.Pointer(session))
}

func (l *cpslNativeLibrary) eval(opts cpslSessionEvalOptions) (string, error) {
	if err := validateFFIString(opts.requestJSON); err != nil {
		return "", err
	}
	value := l.evalFn(unsafe.Pointer(opts.session), opts.requestJSON)
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
