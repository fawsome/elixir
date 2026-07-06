.PHONY: all test build

all: test build

test:
	mix test

build:
	mix fae
	mkdocs build

