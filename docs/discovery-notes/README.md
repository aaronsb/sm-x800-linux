# Discovery notes

Raw working notes from the early port sessions — kept verbatim for provenance,
not maintained as documentation. They read like what they are: session logs,
recon dumps, and staged plans written so the *next session* could pick up fast.
The polished narrative lives one level up in `docs/`.

| File | What it was |
|---|---|
| `00-recon-findings.md` | First-contact recon of the stock device (partitions, security state, IDs) |
| `02-pmos-port-prep.md` | Downstream-first strategy staging (later abandoned for mainline) |
| `03-boot-debug-log.md` | Chronological log of the downstream-kernel boot attempts — a documented dead end |
| `04-mainline-prep.md` | The pivot plan to mainline + visibility keys mined from the stock DTB |
| `wiki-porting-guide.md` | Offline capture of the pmOS wiki porting pages (bot-walled to headless fetch) |

Numbering is preserved from when these sat in `docs/` — `01` and `05`+ remain
there as the maintained story, so the sequence reads across both directories.
