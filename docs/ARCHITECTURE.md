# Architecture notes

## Why the app has no API key

Public repo. Any credential committed here is on the open internet. Rather than
ship an anon key and rely on row-level security being exactly right, the client
talks only to `skippy-api`, which runs with service-role privileges server-side.

Registration is deliberately unauthenticated: it is write-only and low value. The
worst an attacker does is register junk device tokens, which APNs rejects and the
reaper marks ended. Everything that reads or creates work requires the per-install
token issued at registration.

## Traps that cost real time

**The Live Activity push token is not the device token.** It is issued per
Activity, and it rotates. `pushTokenUpdates` must be observed for the whole
lifetime of the Activity or the Island silently goes dark after the first
rotation.

**The APNs topic needs `.push-type.liveactivity` appended** to the bundle id.
Without it Apple accepts the request and delivers nothing.

**A sandbox build must use the sandbox host.** Wrong host yields
`BadDeviceToken` with no other symptom.

**ContentState decoding must not throw.** Postgres emits ISO8601 with fractional
seconds, which the default decoder rejects. A throwing decode is a dropped push
with no error surfaced anywhere, so every field degrades to a default.

**PostgREST needs the schema in `pgrst.db_schemas`.** Grants and `notify pgrst`
alone are not enough; the `authenticator` role setting must list the schema or
every RPC silently returns nothing.

**pg_net commits responses in a separate transaction.** A `DO` block can never
read its own HTTP response.

## Lanes and delegation

A Maestro that delegates becomes a *container*: it stops working, releases its
domain lock, and sits at `blocked` until its children settle. Two bugs came out
of getting this wrong — children were unclaimable while the parent held the lane,
and children born unplanned re-planned themselves recursively instead of
executing.
