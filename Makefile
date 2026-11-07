PREFIX ?= $(HOME)/.local
BIN := $(DESTDIR)$(PREFIX)/bin/paper-exorcist
NAUTILUS_DIR ?= $(HOME)/.local/share/nautilus/scripts
NAUTILUS_SCRIPTS := "$(DESTDIR)$(NAUTILUS_DIR)/Exorcise to PDF" "$(DESTDIR)$(NAUTILUS_DIR)/Exorcise to PDF (scan)"

.PHONY: install install-nautilus uninstall lint test demo

install:
	install -Dm755 paper-exorcist.sh $(BIN)
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "note: $(PREFIX)/bin is not in PATH yet";; esac

# Right-click menu in Files: Scripts → Exorcise to PDF / Exorcise to PDF (scan).
install-nautilus: install
	for script in $(NAUTILUS_SCRIPTS); do install -Dm755 nautilus/exorcise-to-pdf "$$script"; done

uninstall:
	rm -f $(BIN) $(NAUTILUS_SCRIPTS)

# The Python engine lives in a heredoc; lint it as the file it pretends not to be.
lint:
	shellcheck paper-exorcist.sh nautilus/exorcise-to-pdf
	sed -n "/^exec .*<<'PYTHON'$$/,/^PYTHON$$/p" paper-exorcist.sh | sed '1d;$$d' | python3 -m pyflakes

test:
	python3 -m unittest discover -s tests -v

demo:
	python3 tests/make_demo.py docs/demo.jpg
