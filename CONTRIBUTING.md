# Contributing

This is a specification repository. Useful contributions:

- **Findings.** A sequence of events the specs or models handle badly, ideally
  as a Quint trace or a numbered list of steps.
- **Open questions.** Each spec lists its open questions; an argued answer is
  welcome as an issue.
- **Ports and conformance.** Notes on implementing the specs in another
  language, or an adapter that replays the model traces
  (`docs/design/spec-and-model-policy.md`, section 7).

Before proposing a change to `specs/` or `models/`, run

```
devenv shell -- veridian-spec-check
```

It must pass. A model check that is expected to be violated (a recorded finding
or a negative control) and stops being violated also fails the gate, so close
the finding in the spec, the model and `models/README.md` together.

Tag rules and who is authoritative when a spec and a model disagree are in
`docs/design/spec-and-model-policy.md`.
