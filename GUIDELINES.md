# Code Guidelines

## General

Follow general code best practices, such as:

- IMPORTANT: Always aim for the most correct design rather than preserving accidental behavior. Snowcloud is in alpha, so internal compatibility is not a requirement unless explicitly documented. Do not add legacy behavior, migrations, or version increments merely because an internal representation changes. Strict recovery and ownership safety still apply: incompatible persisted state must fail closed rather than being silently ignored or recreated.
- Avoid redundant duplication: if a string or a magic number is being duplicated multiple times, extract it to a single shared place.
- Use descriptive and well-chosen names for variables, functions, and classes.
- Each function should do one 'job' and do it well.
- If you're writing a long comment to explain behavior, that behavior is usually wrong. Code should be largely self-explanatory, though some commenting can be good.
- Avoid reinventing the wheel when a well-known library or tool can accomplish the task effectively.

## Agents

- If subagents are needed, tell those subagents not to create their own subagents, unless explicitly told otherwise.

## Git

- Use concise commit messages in the existing `scope: imperative summary` style, such as `server: add router integration tests` or `core: add app config env parsing`.
- Prefer scopes that match the touched area or crate, such as `rust`, `server`, `db`, `web`, or `core`.
