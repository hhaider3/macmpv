SHELL := /bin/zsh

BUILD_LOG := .build/last-build.log
# Retry condition from the README's Troubleshooting section. Anything else is a
# real compile failure: fail once, with the output shown exactly once.
SANDBOX_ERROR := sandbox_apply: Operation not permitted

.PHONY: build run app dmg dmg-torrents release clean

build:
	@mkdir -p .build
	@set -o pipefail; \
	swift build 2>&1 | tee $(BUILD_LOG) || { \
	    if grep -q "$(SANDBOX_ERROR)" $(BUILD_LOG); then \
	        echo "==> sandbox denial detected; retrying once with --disable-sandbox" >&2; \
	        exec swift build --disable-sandbox; \
	    fi; \
	    exit 1; \
	}

run:
	@mkdir -p .build
	@set -o pipefail; \
	swift run macmpv 2>&1 | tee $(BUILD_LOG) || { \
	    if grep -q "$(SANDBOX_ERROR)" $(BUILD_LOG); then \
	        echo "==> sandbox denial detected; retrying once with --disable-sandbox" >&2; \
	        exec swift run --disable-sandbox macmpv; \
	    fi; \
	    exit 1; \
	}

app:
	zsh Scripts/build-app.sh release

dmg:
	zsh Scripts/package-dmg.sh

dmg-torrents:
	zsh Scripts/package-dmg.sh torrents

release:
	zsh Scripts/release.sh

clean:
	swift package clean
