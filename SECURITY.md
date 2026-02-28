# Security Policy

## Reporting a Vulnerability

Please report suspected vulnerabilities privately to the maintainers.

Include:

- affected version/commit,
- reproduction input,
- observed behavior,
- expected safe behavior,
- impact assessment.

Do not open public issues with exploitable details before maintainers have time to triage and patch.

## Scope

Security-relevant areas include:

- parser bounds safety,
- selector parser and matcher memory safety,
- mutation logic in in-place attribute/entity decode,
- external tool command invocation paths in `tools/scripts.zig`.

## Response Goals

- Acknowledge receipt promptly.
- Triage and determine severity.
- Publish patch and changelog notes when resolved.
