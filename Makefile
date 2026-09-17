IMAGE_NAME ?= quay.io/causa-ai-hub/causa-mcp
IMAGE_TAG  ?= latest
PLATFORMS ?= linux/amd64,linux/arm64

.PHONY: build image image-multiarch load deploy port-forward

## Build the JAR
build:
	./mvnw clean package -DskipTests

## Build the container image
image: build
	docker build -f src/main/docker/Dockerfile.jvm -t $(IMAGE_NAME):$(IMAGE_TAG) .

## Build and push a multi-arch container image
image-multiarch: build
	docker buildx build --platform $(PLATFORMS) -f src/main/docker/Dockerfile.jvm -t $(IMAGE_NAME):$(IMAGE_TAG) --push .

## Load the image into the Kind cluster
load: image
	kind load docker-image $(IMAGE_NAME):$(IMAGE_TAG)

## Deploy to the Kind cluster (IMAGE_TAG is substituted via envsubst)
deploy:
	IMAGE_TAG=$(IMAGE_TAG) envsubst < manifests/causa-mcp-server.yaml | kubectl apply -f -

## Port-forward the MCP server to localhost:8081
port-forward:
	kubectl port-forward -n causa svc/causa-mcp 8081:8081
