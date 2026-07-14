//go:build windows

// cpsl_loader_windows.go loads CPSL dynamic libraries on Windows through
// syscall and exposes the common native-library interface.
package main

import (
	"fmt"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

type cpslSession uintptr

type cpslNativeLibrary struct {
	dll                               *syscall.DLL
	abiVersionProc                    *syscall.Proc
	metadataJSONProc                  *syscall.Proc
	sessionNewProc                    *syscall.Proc
	sessionNewWithHostCallbacksV3Proc *syscall.Proc
	visionRespondProc                 *syscall.Proc
	sessionFreeProc                   *syscall.Proc
	evalProc                          *syscall.Proc
	stringFreeProc                    *syscall.Proc
	lastErrorProc                     *syscall.Proc
	visionCallback                    uintptr
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
	dll, err := syscall.LoadDLL(path)
	if err != nil {
		return nil, fmt.Errorf("load CPSL library: %w", err)
	}
	lib := &cpslNativeLibrary{dll: dll}
	ok := false
	defer func() {
		if !ok {
			_ = lib.close()
		}
	}()

	if lib.abiVersionProc, err = dll.FindProc("cpsl_abi_version"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_abi_version: %w", err)
	}
	if lib.metadataJSONProc, err = dll.FindProc("cpsl_backend_metadata_json"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_backend_metadata_json: %w", err)
	}
	if lib.sessionNewProc, err = dll.FindProc("cpsl_session_new"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_session_new: %w", err)
	}
	lib.sessionNewWithHostCallbacksV3Proc, _ = dll.FindProc("cpsl_session_new_with_host_callbacks_v3")
	lib.visionRespondProc, _ = dll.FindProc("cpsl_vision_respond")
	if lib.sessionFreeProc, err = dll.FindProc("cpsl_session_free"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_session_free: %w", err)
	}
	if lib.evalProc, err = dll.FindProc("cpsl_eval"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_eval: %w", err)
	}
	if lib.stringFreeProc, err = dll.FindProc("cpsl_string_free"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_string_free: %w", err)
	}
	if lib.lastErrorProc, err = dll.FindProc("cpsl_last_error"); err != nil {
		return nil, fmt.Errorf("resolve CPSL symbol cpsl_last_error: %w", err)
	}

	ok = true
	return lib, nil
}

func (l *cpslNativeLibrary) abiVersion() (uint32, error) {
	value, _, _ := l.abiVersionProc.Call()
	return uint32(value), nil
}

func (l *cpslNativeLibrary) backendMetadataJSON() (string, error) {
	value, _, _ := l.metadataJSONProc.Call()
	if value == 0 {
		return "", fmt.Errorf("CPSL metadata failed: %s", l.lastError())
	}
	defer l.stringFreeProc.Call(value)
	return stringFromC(unsafe.Pointer(value)), nil
}

func (l *cpslNativeLibrary) sessionNew(configJSON string) (cpslSession, error) {
	config, err := bytePtrFromString(configJSON)
	if err != nil {
		return 0, err
	}
	value, _, _ := l.sessionNewProc.Call(uintptr(unsafe.Pointer(config)))
	if value == 0 {
		return 0, fmt.Errorf("CPSL session creation failed: %s", l.lastError())
	}
	return cpslSession(value), nil
}

func (l *cpslNativeLibrary) sessionNewWithVision(opts cpslSessionVisionOptions) (cpslSession, error) {
	configJSON, handler := opts.configJSON, opts.handler
	if handler == nil || l.sessionNewWithHostCallbacksV3Proc == nil || l.visionRespondProc == nil {
		return l.sessionNew(configJSON)
	}
	config, err := bytePtrFromString(configJSON)
	if err != nil {
		return 0, err
	}

	callback := func(_ uintptr, inputsPointer uintptr, inputCount uintptr, queryPointer uintptr, responseContext uintptr) uintptr {
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
				inputs = append(inputs, cpslVisionInput{
					Data:      append([]byte(nil), unsafe.Slice((*byte)(input.data), input.dataLen)...),
					Filename:  stringFromC(input.filename),
					MediaType: stringFromC(input.mediaType),
				})
			}
			result, callbackErr = handler(cpslVisionReadOptions{
				inputs: inputs,
				query:  stringFromC(unsafe.Pointer(queryPointer)),
			})
		}()
		if callbackErr != nil {
			result = callbackErr.Error()
		}
		bytes := []byte(result)
		var data uintptr
		if len(bytes) > 0 {
			data = uintptr(unsafe.Pointer(&bytes[0]))
		}
		isError := uintptr(0)
		if callbackErr != nil {
			isError = 1
		}
		l.visionRespondProc.Call(responseContext, data, uintptr(len(bytes)), isError)
		runtime.KeepAlive(bytes)
		return 0
	}
	l.visionCallback = syscall.NewCallback(callback)
	callbacks := cpslVisionCallbacksFFI{handle: l.visionCallback}
	value, _, _ := l.sessionNewWithHostCallbacksV3Proc.Call(
		uintptr(unsafe.Pointer(config)),
		0,
		0,
		0,
		0,
		uintptr(unsafe.Pointer(&callbacks)),
	)
	runtime.KeepAlive(callbacks)
	if value == 0 {
		return 0, fmt.Errorf("CPSL session creation failed: %s", l.lastError())
	}
	return cpslSession(value), nil
}

func (l *cpslNativeLibrary) sessionFree(session cpslSession) {
	l.sessionFreeProc.Call(uintptr(session))
}

func (l *cpslNativeLibrary) eval(opts cpslSessionEvalOptions) (string, error) {
	request, err := bytePtrFromString(opts.requestJSON)
	if err != nil {
		return "", err
	}
	value, _, _ := l.evalProc.Call(uintptr(opts.session), uintptr(unsafe.Pointer(request)))
	if value == 0 {
		return "", fmt.Errorf("CPSL eval failed: %s", l.lastError())
	}
	defer l.stringFreeProc.Call(value)
	return stringFromC(unsafe.Pointer(value)), nil
}

func (l *cpslNativeLibrary) lastError() string {
	value, _, _ := l.lastErrorProc.Call()
	if value == 0 {
		return ""
	}
	return stringFromC(unsafe.Pointer(value))
}

func (l *cpslNativeLibrary) close() error {
	if l == nil || l.dll == nil {
		return nil
	}
	err := l.dll.Release()
	l.dll = nil
	return err
}

func bytePtrFromString(value string) (*byte, error) {
	if strings.Contains(value, "\x00") {
		return nil, fmt.Errorf("CPSL FFI string contains an embedded NUL byte")
	}
	return syscall.BytePtrFromString(value)
}
