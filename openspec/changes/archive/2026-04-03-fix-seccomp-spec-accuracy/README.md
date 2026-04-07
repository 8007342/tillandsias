# fix-seccomp-spec-accuracy

Remove misleading seccomp/close_range awareness hack from podman-orchestration spec. The pre_exec FD sanitization already eliminates the close_range dependency. Update spec to reflect the actual fix instead of documenting awareness of the problem.
