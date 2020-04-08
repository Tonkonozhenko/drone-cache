ROOT_DIR              := $(CURDIR)
SCRIPTS               := $(ROOT_DIR)/scripts

VERSION               := $(strip $(shell [ -d .git ] && git describe --always --tags --dirty))
BUILD_DATE            := $(shell date -u +"%Y-%m-%dT%H:%M:%S%Z")
VCS_REF               := $(strip $(shell [ -d .git ] && git rev-parse --short HEAD))

GO_PACKAGES            = $(shell go list ./... | grep -v -E '/vendor/|/test')
GO_FILES              := $(shell find . -name \*.go -print)

GOPATH                := $(firstword $(subst :, ,$(shell go env GOPATH)))
GOBIN                 := $(GOPATH)/bin

GOCMD                 := go
GOBUILD               := $(GOCMD) build
GOMOD                 := $(GOCMD) mod
GOGET                 := $(GOCMD) get
GOFMT                 := gofmt

GOLANGCI_LINT_VERSION  = v1.21.0
GOLANGCI_LINT_BIN      = $(GOBIN)/golangci-lint
EMBEDMD_BIN            = $(GOBIN)/embedmd
GOTEST_BIN             = $(GOBIN)/gotest
GORELEASER_VERSION     = v0.131.1
GORELEASER_BIN         = $(GOBIN)/goreleaser
LICHE_BIN              = $(GOBIN)/liche

UPX                   := upx

DOCKER                := docker
DOCKER_BUILD          := $(DOCKER) build
DOCKER_PUSH           := $(DOCKER) push
DOCKER_COMPOSE        := docker-compose

.PHONY: default all
default: drone-cache
all: drone-cache

.PHONY: setup
setup:
	$(SCRIPTS)/setup_dev_environment.sh

drone-cache: vendor main.go $(wildcard *.go) $(wildcard */*.go)
	CGO_ENABLED=0 $(GOBUILD) -mod=vendor -a -tags netgo -ldflags '-s -w -X main.version=$(VERSION)' -o $@ .

.PHONY: build
build: main.go $(wildcard *.go) $(wildcard */*.go)
	$(GOBUILD) -mod=vendor -tags netgo -ldflags '-X main.version=$(VERSION)' -o drone-cache .

.PHONY: release
release: drone-cache $(GORELEASER_BIN)
	$(GORELEASER_BIN) release --rm-dist

.PHONY: snapshot
snapshot: drone-cache $(GORELEASER_BIN)
	$(GORELEASER_BIN) release --skip-publish --rm-dist --snapshot

.PHONY: clean
clean:
	rm -f drone-cache
	rm -rf target

tmp/help.txt: drone-cache
	mkdir -p tmp
	$(ROOT_DIR)/drone-cache --help &> tmp/help.txt

README.md: tmp/help.txt
	$(EMBEDMD_BIN) -w README.md

tmp/docs.txt: drone-cache
	@echo "IMPLEMENT ME"

DOCS.md: tmp/docs.txt
	$(EMBEDMD_BIN) -w DOCS.md

docs: clean README.md DOCS.md $(LICHE_BIN)
	@$(LICHE_BIN) --recursive docs --document-root .
	@$(LICHE_BIN) --exclude "(goreportcard.com)" --document-root . *.md

.PHONY: vendor
vendor:
	@$(GOMOD) tidy
	@$(GOMOD) vendor -v

.PHONY: compress
compress: drone-cache
	# Add as dependency
	@$(UPX) drone-cache

.PHONY: container
container: release Dockerfile
	@$(DOCKER_BUILD) --build-arg BUILD_DATE="$(BUILD_DATE)" \
		--build-arg VERSION="$(VERSION)" \
		--build-arg VCS_REF="$(VCS_REF)" \
		--build-arg DOCKERFILE_PATH="/Dockerfile" \
		-t meltwater/drone-cache:latest .

.PHONY: container-dev
container-dev: snapshot Dockerfile
	@$(DOCKER_BUILD) --build-arg BUILD_DATE="$(BUILD_DATE)" \
		--build-arg VERSION="$(VERSION)" \
		--build-arg VCS_REF="$(VCS_REF)" \
		--build-arg DOCKERFILE_PATH="/Dockerfile" \
		--no-cache \
		-t meltwater/drone-cache:dev .

.PHONY: container-push
container-push: container
	$(DOCKER_PUSH) meltwater/drone-cache:latest

.PHONY: container-push-dev
container-push-dev: container-dev
	$(DOCKER_PUSH) meltwater/drone-cache:dev

.PHONY: test
test: $(GOTEST_BIN)
	$(DOCKER_COMPOSE) up -d && sleep 1
	-$(GOTEST_BIN) -race -short -cover -failfast -tags=integration ./...
	$(DOCKER_COMPOSE) down -v

.PHONY: test-integration
test-integration: $(GOTEST_BIN)
	$(DOCKER_COMPOSE) up -d && sleep 1
	-$(GOTEST_BIN) -race -cover -tags=integration -v ./...
	$(DOCKER_COMPOSE) down -v

.PHONY: test-unit
test-unit: $(GOTEST_BIN)
	$(GOTEST_BIN) -race -cover -benchmem -v ./...

.PHONY: test-e2e
test-e2e: $(GOTEST_BIN)
	$(DOCKER_COMPOSE) up -d && sleep 1
	-$(GOTEST_BIN) -race -cover -tags=integration -v ./internal/plugin
	$(DOCKER_COMPOSE) down -v

.PHONY: lint
lint: $(GOLANGCI_LINT_BIN)
	# Check .golangci.yml for configuration
	$(GOLANGCI_LINT_BIN) run -v --enable-all --skip-dirs tmp -c .golangci.yml

.PHONY: fix
fix: $(GOLANGCI_LINT_BIN) format
	$(GOLANGCI_LINT_BIN) run --fix --enable-all --skip-dirs tmp -c .golangci.yml

.PHONY: format
format:
	@$(GOFMT) -w -s $(GO_FILES)

$(GOTEST_BIN):
	GO111MODULE=off $(GOGET) -u github.com/rakyll/gotest

$(EMBEDMD_BIN):
	GO111MODULE=off $(GOGET) -u github.com/campoy/embedmd

$(GOLANGCI_LINT_BIN):
	curl -sfL https://raw.githubusercontent.com/golangci/golangci-lint/$(GOLANGCI_LINT_VERSION)/install.sh \
		| sed -e '/install -d/d' \
		| sh -s -- -b $(GOBIN) $(GOLANGCI_LINT_VERSION)

$(GORELEASER_BIN):
	curl -sfL https://install.goreleaser.com/github.com/goreleaser/goreleaser.sh \
		| VERSION=$(GORELEASER_VERSION) sh -s -- -b $(GOBIN) $(GORELEASER_VERSION)

$(LICHE_BIN):
	GO111MODULE=on $(GOGET) -u github.com/raviqqe/liche
