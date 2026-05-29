# Sikker Selvbetjening Config

Configuration and image-overlay repository for Sikker Selvbetjening.

This project defines target-specific configuration, renders normalized overlay data, and builds derived container images on top of the shared base image.

## Purpose

The repository is responsible for:

- Declaring per-target configuration in a structured format
- Validating configuration against shared schemas
- Rendering an overlay payload for each build target
- Applying overlays with helper tooling from the base image
- Building and publishing target-specific images

## How it works

1. Build targets are selected from the inventory configuration.
2. Target configuration is loaded and merged in deterministic order.
3. The merged configuration is normalized and written as overlay payload.
4. Base-image overlay helpers transform payload data into concrete filesystem changes.
5. A derived image is built from the base image and pushed with standard tags.

## Repository structure

- config/
	- Configuration input for targets and environments
- playbooks/
	- Rendering and operational playbooks
- scripts/
	- Local and CI helper scripts for validation and image builds
- templates/
	- Reusable template fragments used during render steps

## Validation model

Validation is done in two layers:

- Schema validation: configuration is validated against the shared schema contract.
- Logical validation: additional checks ensure internally consistent settings before build.

The schema contract is sourced from the base image, which keeps configuration validation aligned with runtime expectations.

## Build and release

The image build flow is target-oriented and designed for CI matrix execution:

- Render target overlay into a build directory
- Apply helper-driven transformations from the base image
- Build derived image
- Tag and push to registry

Tags typically include latest and immutable identifiers (for example date and commit-derived tags).

## Relationship to the base image

This repository depends on the base image in two important ways:

- It reads schema definitions from the base image to validate configuration.
- It runs base-image overlay helper tools to materialize final filesystem changes.

This makes schema locations and helper interfaces a compatibility boundary between the two repositories.

## Typical usage

Use this repository when you need to:

- Build a configuration-specific image for one or more targets
- Validate configuration changes before publishing
- Produce reproducible overlays for deployment pipelines

## Development notes

- Prefer small, incremental configuration changes per target.
- Run validation before building and pushing images.
- Keep render logic deterministic so CI and local runs produce identical output.
