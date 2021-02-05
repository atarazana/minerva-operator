include settings.sh

# Default bundle image tag
BUNDLE_IMG ?= quay.io/$(USERNAME)/$(OPERATOR_NAME)-bundle:v$(VERSION)
FROM_BUNDLE_IMG ?= quay.io/$(USERNAME)/$(OPERATOR_NAME)-bundle:v$(FROM_VERSION)
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Bundle Index tag
BUNDLE_INDEX_IMG ?= quay.io/$(USERNAME)/$(OPERATOR_NAME)-index:v$(VERSION)
FROM_BUNDLE_INDEX_IMG ?= quay.io/$(USERNAME)/$(OPERATOR_NAME)-index:v$(FROM_VERSION)

# Catalog default namespace
CATALOG_NAMESPACE?=olm

# Image URL to use all building/pushing image targets
IMG ?= quay.io/$(USERNAME)/$(OPERATOR_IMAGE):v$(VERSION)

all: docker-build

# Run against the configured Kubernetes cluster in ~/.kube/config
run: ansible-operator
	$(ANSIBLE_OPERATOR) run

# Install CRDs into a cluster
install: kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Undeploy controller in the configured Kubernetes cluster in ~/.kube/config
undeploy: kustomize
	$(KUSTOMIZE) build config/default | kubectl delete -f -

# Build the docker image
docker-build:
	docker build . -t ${IMG}

# Push the docker image
docker-push:
	docker push ${IMG}

PATH  := $(PATH):$(PWD)/bin
SHELL := env PATH=$(PATH) /bin/sh
OS    = $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH  = $(shell uname -m | sed 's/x86_64/amd64/')
OSOPER   = $(shell uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/apple-darwin/' | sed 's/linux/linux-gnu/')
ARCHOPER = $(shell uname -m )

kustomize:
ifeq (, $(shell which kustomize 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p bin ;\
	curl -sSLo - https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v3.5.4/kustomize_v3.5.4_$(OS)_$(ARCH).tar.gz | tar xzf - -C bin/ ;\
	}
KUSTOMIZE=$(realpath ./bin/kustomize)
else
KUSTOMIZE=$(shell which kustomize)
endif

ansible-operator:
ifeq (, $(shell which ansible-operator 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p bin ;\
	curl -LO https://github.com/operator-framework/operator-sdk/releases/download/v1.2.0/ansible-operator-v1.2.0-$(ARCHOPER)-$(OSOPER) ;\
	mv ansible-operator-v1.2.0-$(ARCHOPER)-$(OSOPER) ./bin/ansible-operator ;\
	chmod +x ./bin/ansible-operator ;\
	}
ANSIBLE_OPERATOR=$(realpath ./bin/ansible-operator)
else
ANSIBLE_OPERATOR=$(shell which ansible-operator)
endif

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: kustomize
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# Push the bundle image.
bundle-push: bundle-build
	docker push $(BUNDLE_IMG)

# Do all the bundle stuff
bundle-validate: bundle-push
	operator-sdk bundle validate $(BUNDLE_IMG)

# Do all bundle stuff
bundle-all: bundle-build bundle-push bundle-validate

# Bundle Index
# Build bundle by referring to the previous version if FROM_VERSION is defined
ifndef FROM_VERSION
  CREATE_BUNDLE_INDEX  := true
endif
index-build:
ifeq ($(CREATE_BUNDLE_INDEX),true)
	opm -u docker index add --bundles $(BUNDLE_IMG) --tag $(BUNDLE_INDEX_IMG)
else
	echo "FROM_VERSION ${FROM_VERSION}"
	opm -u docker index add --bundles $(BUNDLE_IMG) --from-index $(FROM_BUNDLE_INDEX_IMG) --tag $(BUNDLE_INDEX_IMG)
endif
	
# Push the index
index-push: index-build
	docker push $(BUNDLE_INDEX_IMG)

# [DEBUGGING] Export the index (pulls image) to download folder
index-export:
	opm index export --index="$(BUNDLE_INDEX_IMG)" --package="$(OPERATOR_NAME)"

# [DEBUGGING] Create a test sqlite db and serves it
index-registry-serve:
	opm registry add -b $(FROM_BUNDLE_IMG) -d "test-registry.db"
	opm registry add -b $(BUNDLE_IMG) -d "test-registry.db"
	opm registry serve -d "test-registry.db" -p 50051

# [DEMO] Deploy previous index then create a sample subscription then deploy current index
catalog-deploy-prev: # 1. Install Catalog version 0.0.1
	sed "s|BUNDLE_INDEX_IMG|$(FROM_BUNDLE_INDEX_IMG)|" ./config/catalog/catalog-source.yaml | kubectl apply -n $(CATALOG_NAMESPACE) -f -

install-operator:    # 2. Install Operator => Create AppService and create sample data
	kubectl operator install $(OPERATOR_NAME) --create-operator-group -v v$(FROM_VERSION)
	kubectl operator list

catalog-deploy:      # 3. Upgrade Catalog to version 0.0.2
	sed "s|BUNDLE_INDEX_IMG|$(BUNDLE_INDEX_IMG)|" ./config/catalog/catalog-source.yaml | kubectl apply -n $(CATALOG_NAMESPACE) -f -

upgrade-operator:    # 4. Upgrade Operator, since it's manual this step approves the install plan. Notice schema upgraded and data migrated!
	kubectl operator upgrade $(OPERATOR_NAME)

uninstall-operator:  # 5. Clean 1. Unistall Operator and delete AppService object
	kubectl operator uninstall $(OPERATOR_NAME) --delete-operator-groups

catalog-undeploy:    # 6. Clean 2. Delete Catalog
	sed "s|BUNDLE_INDEX_IMG|$(BUNDLE_INDEX_IMG)|" ./config/catalog/catalog-source.yaml | kubectl delete -n $(CATALOG_NAMESPACE) -f -

all-in-one: docker-build docker-push bundle-build bundle-push index-build index-push