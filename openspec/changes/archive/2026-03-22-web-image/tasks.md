## 1. Container Image

- [x] 1.1 Create `images/web/Containerfile` based on `docker.io/library/alpine:latest` with WORKDIR `/var/www`, EXPOSE 8080, and CMD running `busybox httpd -f -p 8080 -h /var/www`
- [x] 1.2 Create `images/web/entrypoint.sh` that prints a banner with the project name and serving URL, then execs httpd
- [x] 1.3 Verify the image builds successfully with `podman build -t tillandsias-web:latest -f images/web/Containerfile images/web/`
- [x] 1.4 Verify the built image is under 10MB

## 2. OpenSpec Artifacts

- [x] 2.1 Write `openspec/changes/web-image/proposal.md` explaining why a tiny httpd image is needed
- [x] 2.2 Write `openspec/changes/web-image/design.md` with Alpine + busybox httpd decisions
- [x] 2.3 Write `openspec/changes/web-image/specs/web-image/spec.md` with requirements and scenarios
- [x] 2.4 Write `openspec/changes/web-image/tasks.md` with implementation tasks
