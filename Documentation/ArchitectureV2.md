# Crypta Storage Architecture v2

## Security boundary

Crypta v2 is a local-only encrypted media store. The design protects media,
titles, original extensions, durations, playback positions, thumbnails, and
vault names at rest. It does not send those values to a server and does not
include them in migration progress or diagnostic messages.

The operating system, a process running as the signed-in user with sufficient
permissions, or a compromised application process remain outside the at-rest
threat model. Standard vault external playback necessarily creates a temporary
plaintext copy for the selected external player. Extended and maximum vaults
never use that route.

## Key hierarchy

```text
catalog key (Keychain, device only)
├── vault names
└── standard-vault device wrappers

vault master key (one random 256-bit key per vault)
├── encrypted object metadata
├── encrypted thumbnails
└── object data-encryption keys
    └── authenticated media chunks

recovery key (printable, checksummed 256-bit key)
└── authenticated recovery envelope
    ├── vault master key
    └── catalog key
```

Standard vault master keys are device-wrapped for unattended local access.
Extended and maximum vault master keys use Secure Enclave P-256 key agreement
with user-presence access control. A recovery envelope is independent of the
device wrapper, so loss of the local Secure Enclave identity or catalog
Keychain item does not destroy the data. Recovery first decrypts the catalog
key from the selected vault's envelope, validates that key against the encrypted
catalog, restores it to Keychain, and reenrolls that vault on the current
device. Device reenrollment creates a new immutable key slot, commits its
envelope first, and only then retires the previous slot, avoiding an overwrite
window that could strand the device wrapper.

Unlocked vault keys live only in explicit, revocable sessions. A lock operation
invalidates the session and clears media-reader caches.

The metadata schema records recovery-key confirmation independently for each
vault. A newly created vault is not considered ready until the user has
explicitly confirmed that the displayed recovery key was stored safely. A
replacement recovery key is committed as a new authenticated envelope before
the previous presentation is dismissed.

If the catalog Keychain item or a vault's device key is no longer usable, the
app presents a local recovery-key entry surface. Recovery can be restricted to
the selected vault, preventing a valid key for a different vault from silently
reenrolling the wrong device slot. The submitted phrase is parsed in memory,
is never logged, and is cleared from the view after a successful recovery.

## Storage layout

```text
Application Support/Crypta/Vault-v2/
├── metadata.sqlite3
├── Objects/
├── Staging/
└── Thumbnails/

Caches/Crypta/
├── V2/Playback/
└── Sessions/<process-owned session>/Adopted/
```

Directories use owner-only permissions. SQLite runs with foreign keys, WAL,
`synchronous=FULL`, and an integrity check. Its plaintext columns contain only
random identifiers, opaque blob names, ordering, counts, and timestamps.
User-visible metadata is independently authenticated and encrypted.

Standard-vault external playback is first materialized under the v2 playback
staging directory, then atomically adopted into a process-owned session before
it is handed to another app. Normal lease release and app shutdown remove the
plaintext. Startup validates both the owner PID and process start time, then
removes sessions left by a crash without deleting a directory owned by a
reused PID.

## Media container

Every object is a separate authenticated `CRYPTA02` container:

- a fixed authenticated header identifies the format, vault, object, revision,
  plaintext length, and chunk geometry;
- a random object data-encryption key is wrapped by the vault master key;
- media is encrypted in independently authenticated 4 MiB AES-GCM chunks;
- nonces are derived from a random per-object prefix plus the chunk index;
- chunk authentication binds the header, index, and exact plaintext length;
- exact container length is validated before reading.

This permits constant-time random access for built-in playback while detecting
header edits, truncation, appended bytes, reordered chunks, and cross-object
splicing.

## Transactional import

An import follows a strict commit order:

1. Stream plaintext into a temporary encrypted container.
2. Authenticate every staged chunk.
3. Atomically move the container into `Objects` and synchronize the directory.
4. Commit encrypted metadata in SQLite.
5. Reopen and authenticate the committed container.
6. Only then remove the source file when removal was requested.

Failures before final verification roll back the uncommitted v2 copy and retain
the source. A failure after final verification retains both copies rather than
risk deleting the only usable source. When final verification succeeds but the
source cannot be removed, the import remains committed and the UI explicitly
warns how many plaintext source files still need attention.

## Migration from v1

Migration reads the legacy encrypted chunks only inside the local migration
process. Each chunk is decrypted in memory and streamed directly into a v2
container; no intermediate plaintext file is written.

Progress is resumable and contains only phase and aggregate counts. Existing
object IDs make completed items idempotent. After every expected object exists,
the migrator authenticates every v2 container again. The legacy package and
legacy Keychain entry are removed only after that verification succeeds and
cleanup was explicitly requested.

Migration initialization creates every target vault and the first progress
checkpoint in one SQLite transaction. After an interruption, continuation uses
the already committed device wrappers and does not require the recovery phrase
to remain in application memory. Legacy encrypted thumbnails are decrypted in
memory and immediately re-encrypted under the destination vault key.

The production migrator must never be pointed at a real vault during automated
tests. Tests construct synthetic v1 stores in temporary directories.

## Playback policy

| Vault level | Video | Image |
| --- | --- | --- |
| Standard | External player allowed | External viewer allowed |
| Extended | Built-in only | Built-in only |
| Maximum | Built-in only | Built-in only |

External materialization is guarded in the storage layer, not only in the UI.
Unsupported formats in extended or maximum vaults remain safely stored even
when the built-in media framework cannot decode them.

## Product integration

The live library is backed exclusively by the v2 store. Standard-vault titles
are loaded automatically; protected-vault object metadata is loaded only into
memory after successful user-presence authentication and is purged again when
the vault locks.

The first 19 recovery, migration, and protected-format strings come from the
approved `crypta-copy-review (2).json` export dated 2026-07-28. The recovery
entry and rare failure-state strings identified by the subsequent security
audit were directly authorized on the same date and are now integrated.

Subtitle generation, subtitle embedding, the Settings scene, and the Quick
Look plaintext-preview route have been removed.
