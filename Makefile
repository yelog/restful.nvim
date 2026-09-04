.PHONY: test format format-check

test:
	./scripts/test.sh

format:
	stylua lua tests

format-check:
	stylua --check lua tests
