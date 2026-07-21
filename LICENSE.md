# License

This repository intentionally carries two licenses, following the upstream
projects each part feeds into:

| Path | License | Rationale |
|---|---|---|
| `pmaports-overlay/device/testing/linux-postmarketos-qcom-sm8450/` (DTS, drivers, patches, config) | **GPL-2.0-only** | Linux kernel sources — several drivers are derived from Samsung's GPL downstream kernel |
| `pmaports-overlay/uniloader-port/` | **GPL-2.0-only** | uniLoader is GPL-2.0 |
| `pmaports-overlay/device/testing/device-samsung-gts8pwifi/` (packaging, scripts) | **MIT** | postmarketOS device packages are conventionally MIT |
| `docs/`, `device-facts/`, `tools/` (documentation, runbooks, helpers) | **MIT** | Maximum reuse for other porters |

Full license texts: [GPL-2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt)
· [MIT](https://opensource.org/license/mit)

Not covered by any license here because it is **never in this repository**:
Samsung's proprietary content (firmware blobs, stock partition dumps, stock
DTBs). The repo ships extractors (`gts8pwifi-fw-extract`) so you pull those
from your own device — see the README's "Should you try this?" section.
