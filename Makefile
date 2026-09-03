.PHONY: build test bundle clean
build:
	swift build -c release
test:
	swift build && swift run unbiased-ax-tests
bundle: build
	scripts/bundle.sh
clean:
	rm -rf .build dist
