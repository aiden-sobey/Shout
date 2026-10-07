ENGINE := engine
APP := app
# With only the Command Line Tools, swift-testing's macros live outside the default plugin path.
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)
MODEL ?= small.en

.PHONY: setup engine-setup engine-download app bundle install run self-test test test-engine test-engine-slow test-app bench clean

setup: engine-setup engine-download bundle  ## Everything needed for a first run

engine-setup:  ## Create engine/.venv with WhisperX
	cd $(ENGINE) && uv sync

engine-download:  ## Download a model: make engine-download MODEL=base.en
	cd $(ENGINE) && uv run shout-engine download $(MODEL)

app:  ## Debug build of the Swift app
	swift build --package-path $(APP)

bundle:  ## Build and sign build/Shout.app
	scripts/bundle.sh

install:  ## Build, install to ~/Applications and launch
	scripts/install.sh

run: install

self-test: bundle  ## Run the app's engine round trip on a fixture (no UI or permissions needed)
	build/Shout.app/Contents/MacOS/Shout --self-test $(ENGINE)/tests/fixtures/ten.wav

test: test-engine test-app  ## Fast tests (no model needed)

test-engine:
	cd $(ENGINE) && uv run pytest -q

test-engine-slow:  ## Real transcription tests (needs small.en and tiny.en downloaded)
	cd $(ENGINE) && uv run pytest -q -m slow

test-app:
	swift test --package-path $(APP) $(SWIFT_TEST_FLAGS)

bench:  ## Milestone 0 benchmark on this machine
	cd $(ENGINE) && uv run shout-engine bench tests/fixtures/short.wav tests/fixtures/ten.wav tests/fixtures/long.wav \
		--models tiny.en base.en small.en --threads 4 6 8 --beams 1 5 --runs 5

clean:
	rm -rf build $(APP)/.build
