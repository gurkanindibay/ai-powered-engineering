# Build from the repository root. Add project-specific compilers/caches in a
# derivative image for Rust/Flutter/.NET gates; no credentials belong here.
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
COPY scripts/engineering_harness/*.py /opt/engineering_harness/
COPY config/engineering-harness/model-registry.example.json /opt/models.json
ENV PYTHONPATH=/opt
ENTRYPOINT ["python3", "-m", "engineering_harness.gateway_bridge"]
