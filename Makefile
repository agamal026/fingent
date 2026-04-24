SHELL := /bin/bash

.PHONY: validate build-sandbox generate-data setup

validate:
	./scripts/validate.sh

build-sandbox:
	docker build -t fingent-sandbox:latest -f $(CURDIR)/docker/Dockerfile $(CURDIR)/docker

generate-data:
	./scripts/generate-data.sh

setup:
	./scripts/setup.sh
