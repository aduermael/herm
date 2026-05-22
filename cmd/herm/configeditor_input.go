// configeditor_input.go handles CSI and encoded-key input for the config editor.
package main

type handleConfigCSISequenceOptions struct {
	seq      csiSequence
	readByte func() (byte, bool)
}

func (a *App) handleConfigCSISequence(opts handleConfigCSISequenceOptions) {
	seq, readByte := opts.seq, opts.readByte
	if len(seq.params) > 0 && seq.final != '~' && seq.final != 'u' {
		return
	}

	switch seq.final {
	case 'A': // Up
		if a.cfgCursor > 0 {
			a.cfgCursor--
		} else {
			fields := a.cfgCurrentFields()
			if len(fields) > 0 {
				a.cfgCursor = len(fields) - 1
			}
		}
		a.cfgTabCursor[a.cfgTab] = a.cfgCursor
		a.renderInput()
	case 'B': // Down
		fields := a.cfgCurrentFields()
		if a.cfgCursor < len(fields)-1 {
			a.cfgCursor++
		} else {
			a.cfgCursor = 0
		}
		a.cfgTabCursor[a.cfgTab] = a.cfgCursor
		a.renderInput()
	case 'C': // Right - next tab
		a.cfgTabCursor[a.cfgTab] = a.cfgCursor
		a.cfgTab++
		if a.cfgTab >= len(cfgTabNames) {
			a.cfgTab = cfgTabDeployments
		}
		a.cfgCursor = a.cfgTabCursor[a.cfgTab]
		a.clampConfigCursor()
		a.renderInput()
	case 'D': // Left - prev tab
		a.cfgTabCursor[a.cfgTab] = a.cfgCursor
		a.cfgTab--
		if a.cfgTab < 0 {
			a.cfgTab = len(cfgTabNames) - 1
		}
		a.cfgCursor = a.cfgTabCursor[a.cfgTab]
		a.clampConfigCursor()
		a.renderInput()
	case '~':
		if string(seq.params) == "200" {
			_ = readBracketedPaste(readByte)
		} else if mod, code, ok := parseModifyOtherKeysParams(seq.params); ok {
			a.handleConfigEncodedKey(handleConfigEncodedKeyOptions{mod: mod, code: code})
		}
	case 'u':
		code, mod, ok := parseCSIUParams(seq.params)
		if ok {
			a.handleConfigEncodedKey(handleConfigEncodedKeyOptions{mod: mod, code: code})
		}
	}
}

type handleConfigEncodedKeyOptions struct {
	mod  int
	code int
}

func (a *App) handleConfigEncodedKey(opts handleConfigEncodedKeyOptions) {
	if opts.code == '\033' {
		a.exitConfigMode(false)
		return
	}
	_, _, isCtrl := decodeCSIEncodedModifier(opts.mod)
	if isCtrl {
		a.handleEncodedKey(handleEncodedKeyOptions{mod: opts.mod, code: opts.code})
	}
}

type handleConfigEditCSISequenceOptions struct {
	seq      csiSequence
	readByte func() (byte, bool)
}

func (a *App) handleConfigEditCSISequence(opts handleConfigEditCSISequenceOptions) {
	seq, readByte := opts.seq, opts.readByte
	if len(seq.params) > 0 && seq.final != '~' && seq.final != 'u' {
		return
	}

	switch seq.final {
	case 'C': // Right
		if a.cfgEditCursor < len(a.cfgEditBuf) {
			a.cfgEditCursor++
			a.renderInput()
		}
	case 'D': // Left
		if a.cfgEditCursor > 0 {
			a.cfgEditCursor--
			a.renderInput()
		}
	case 'H': // Home
		a.cfgEditCursor = 0
		a.renderInput()
	case 'F': // End
		a.cfgEditCursor = len(a.cfgEditBuf)
		a.renderInput()
	case '~':
		switch string(seq.params) {
		case "200":
			a.insertConfigEditText(readBracketedPaste(readByte))
			a.renderInput()
		case "3":
			if a.cfgEditCursor < len(a.cfgEditBuf) {
				a.cfgEditBuf = append(a.cfgEditBuf[:a.cfgEditCursor], a.cfgEditBuf[a.cfgEditCursor+1:]...)
				a.renderInput()
			}
		default:
			if mod, code, ok := parseModifyOtherKeysParams(seq.params); ok {
				a.handleConfigEditEncodedKey(handleConfigEditEncodedKeyOptions{mod: mod, code: code})
			}
		}
	case 'u':
		code, mod, ok := parseCSIUParams(seq.params)
		if ok {
			a.handleConfigEditEncodedKey(handleConfigEditEncodedKeyOptions{mod: mod, code: code})
		}
	}
}

type handleConfigEditEncodedKeyOptions struct {
	mod  int
	code int
}

func (a *App) handleConfigEditEncodedKey(opts handleConfigEditEncodedKeyOptions) {
	if opts.code == '\033' {
		a.cfgEditing = false
		a.cfgEditBuf = nil
		a.renderInput()
		return
	}
	a.handleEncodedKey(handleEncodedKeyOptions{
		mod:                opts.mod,
		code:               opts.code,
		insertRune:         a.insertConfigEditRune,
		deleteWordBackward: a.deleteConfigEditWordBackward,
		render:             a.renderInput,
	})
}

func (a *App) insertConfigEditText(s string) {
	for _, r := range s {
		a.insertConfigEditRune(r)
	}
}

func (a *App) insertConfigEditRune(r rune) {
	a.cfgEditBuf = append(a.cfgEditBuf, 0)
	copy(a.cfgEditBuf[a.cfgEditCursor+1:], a.cfgEditBuf[a.cfgEditCursor:])
	a.cfgEditBuf[a.cfgEditCursor] = r
	a.cfgEditCursor++
}

func (a *App) deleteConfigEditWordBackward() {
	if a.cfgEditCursor <= 0 {
		return
	}
	i := a.cfgEditCursor - 1
	for i > 0 && a.cfgEditBuf[i] == ' ' {
		i--
	}
	for i > 0 && a.cfgEditBuf[i-1] != ' ' {
		i--
	}
	a.cfgEditBuf = append(a.cfgEditBuf[:i], a.cfgEditBuf[a.cfgEditCursor:]...)
	a.cfgEditCursor = i
}
