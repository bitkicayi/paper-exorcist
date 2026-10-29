PREFIX ?= $(HOME)/.local
BIN := $(DESTDIR)$(PREFIX)/bin/paper-exorcist

.PHONY: install uninstall lint test demo

install:
	install -Dm755 paper-exorcist.sh $(BIN)
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "note: $(PREFIX)/bin is not in PATH yet";; esac

uninstall:
	rm -f $(BIN)

# The Python engine lives in a heredoc; lint it as the file it pretends not to be.
lint:
	shellcheck paper-exorcist.sh
	sed -n "/^exec .*<<'PYTHON'$$/,/^PYTHON$$/p" paper-exorcist.sh | sed '1d;$$d' | python3 -m pyflakes

test:
	python3 -m unittest discover -s tests -v

demo:
	python3 tests/make_demo.py docs/demo.jpg
