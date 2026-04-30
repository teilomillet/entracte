.PHONY: help install setup start check bootstrap test all

ARGS ?=

help:
	@echo "Targets: install, setup, start, check, bootstrap, test, all"
	@echo "Use ARGS='...' to pass options, for example:"
	@echo "  make install ARGS='--runtime sari/claude_code --sari-bin /path/to/sari/scripts/sari_app_server'"

install:
	./setup $(ARGS)

setup: install

start:
	./entracte start $(ARGS)

check:
	./entracte check $(ARGS)

bootstrap:
	./entracte bootstrap $(ARGS)

test:
	$(MAKE) -C elixir test

all:
	$(MAKE) -C elixir all
