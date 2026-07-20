# CONTEXT — Plugs

## Intent

HTTP middleware (Plugs) for the EvoDash web layer.

## API Surface

### `EvoDashWeb.Plugs.Locale`

A Plug that sets the Gettext locale per request. Resolution order:

1. Cookie (`locale` key)
2. `Accept-Language` header (parsed, best match selected)
3. Default `"en"`

Fifteen languages are supported.

## Constraints

- Plugs should be minimal and side-effect-free beyond conn manipulation.
- Do not add business logic here.

## Routing Table

None — leaf directory, no child subdirectories.
