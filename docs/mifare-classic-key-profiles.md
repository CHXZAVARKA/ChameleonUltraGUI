# MIFARE Classic key profiles

A key profile keeps verified sector-key assignments without turning them into
a flat dictionary. The read-card flow checks the assigned profile first and
uses the selected dictionary only for unresolved Key A and Key B slots.

Profiles contain plaintext keys. Exported files should be treated as private
credential material.

Profiles remain local unless they are exported explicitly. They are excluded
from the app's generic settings JSON and QR backup because that path is not a
credential export and could otherwise disclose keys together with sector and
UID assignments.

## Saved Cards integration

Profiles saved after a successful read are stored through the same local
preferences provider used by the read flow. They appear automatically in the
**Assigned key profiles** section of **Saved Cards**. That section is the
single place to import, inspect, export, or delete profiles.

## File format

Version 1 groups repeated keys instead of storing the same 12 hexadecimal
characters for every sector:

```json
{
  "format": "chameleon-ultra-gui-mf1-key-profile",
  "version": 1,
  "id": "a-profile-id",
  "name": "Office doors",
  "cardType": "m4k",
  "sectorCount": 40,
  "uid": "01020304",
  "keys": [
    {
      "key": "FFFFFFFFFFFF",
      "keyA": [0, 1, 4],
      "keyB": [1, 4]
    }
  ]
}
```

The arrays contain sector numbers, not block numbers. A MIFARE Classic key is
assigned to a sector, while the number of blocks per sector changes in 4K
cards. `uid` is an optional selection hint: a profile with a different UID can
still be used after explicit confirmation.

At runtime the file is expanded into the existing 80-slot layout:

- Key A for sector `n`: slot `n`
- Key B for sector `n`: slot `40 + n`

Only keys whose live authentication succeeded are included when a profile is
created from a read-card session.

## Read order

The app checks sectors in ascending order. For each sector it checks Key A and
then Key B. The profile lookup is direct: the app tries the key assigned to the
current sector and key type before it scans the ordinary flat dictionary.

The Chameleon firmware starts a new RF interaction for every authentication or
block command. The compact file format therefore reduces stored duplicates; it
does not combine multiple sectors into one authentication command.

## Dump integrity

New MIFARE Classic reads and exact-size BIN imports record whether the dump is
complete. Supported complete images are:

| Variant | Image size | Sectors |
| --- | ---: | ---: |
| Mini | 320 bytes | 5 |
| 1K | 1024 bytes | 16 |
| 1K EV1 | 1152 bytes | 18 |
| 2K | 2048 bytes | 32 |
| 4K | 4096 bytes | 40 |

BIN export is available only when the completeness marker is true and every
expected block is exactly 16 bytes. Missing blocks, malformed blocks, extra
non-empty blocks, and a tag type that disagrees with the data geometry all
block BIN export. A partial recovery can still be kept in Saved Cards and
exported as JSON without claiming it is a complete card image.

Legacy saved cards have no completeness marker. Their data remains available
as saved-card data, but it is not silently promoted to a complete BIN dump.

## Standard MIFARE Classic maintenance

The Write Card page has a separate **Standard MIFARE Classic** mode for
writing a card's own complete dump. This is intentionally separate from the
existing Magic-card writer.

Supported complete images are:

| Variant | Image size | Sectors | Writable data blocks |
| --- | ---: | ---: | ---: |
| Mini | 320 bytes | 5 | 14 |
| 1K | 1024 bytes | 16 | 47 |
| 1K EV1 | 1152 bytes | 18 | 53 |
| 2K | 2048 bytes | 32 | 95 |
| 4K | 4096 bytes | 40 | 215 |

The mode accepts only one of these exact `.bin` sizes or a structurally valid
saved card. New reads and exact-size binary imports carry an explicit
completeness marker. Older saved entries predate that marker, so their first
selection shows a warning and requires confirmation. Confirmation stores the
marker for later use. A legacy entry is never offered when an expected block
is absent or is not exactly 16 bytes. The image geometry must match the
assigned-key profile. A 1K EV1 profile uses `cardType: "m1k"` with
`sectorCount: 18`, so it cannot be confused with a normal 16-sector 1K
profile.

The app runs a full preflight before enabling the write action. Preflight
verifies:

- the presented tag family and capacity match the image;
- the dump and current manufacturer block are identical;
- the UID remains stable while every sector is checked;
- assigned keys authenticate against the live card;
- the current access bits are valid and allow both writing and read-back.

If the assigned profile carries a UID hint, it must also match the presented
card. Unlike the read flow, this mode has no confirmation override for a UID
mismatch: a mismatch here would mean authenticating against, and writing
onto, a different physical card than the one the profile was built for.

Only changed data blocks are written. Block 0 and every sector trailer stay
untouched, so this mode does not change the UID, keys, access bits, or user
byte. Before every write the card UID is scanned again, and every successful
write is immediately read back and compared byte-for-byte. The operation stops
on the first error or mismatch and does not retry a write automatically.

Maintenance plans are bound to the device port that created them and can be
used only once. Execute starts with a read-only revalidation of every data block
seen during preflight, including blocks that already matched the image. No write
starts if any source byte changed. After this complete revalidation, the app
scans the card UID immediately before each individual write. If a card
disappears, changes, or is replaced, only earlier read-back-verified blocks are
considered complete. The error shown to the user includes that count. If the
write response and read-back are both lost, the result of that block is reported
as unknown and the app does not retry it.

The current device protocol performs identity scans and writes as separate RF
commands. Software therefore cannot make the UID check and the following write
atomic. Keep exactly one card on the antenna and do not move or replace it
during preflight or writing.
