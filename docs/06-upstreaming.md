# Conventions, versioning, and contributing back

How we keep this port maintainable and, eventually, upstreamable. Three separate
upstreams matter, each with different rules.

## 1. Where each piece is destined to go

| Our file | Upstream | Rules |
|---|---|---|
| `sm8450-samsung-gts8pwifi.dts` | **Linux** (`arch/arm64/boot/dts/qcom/`) | kernel DT bindings; plain-text patch to the arm64/qcom list |
| `board-gts8pwifi.c`, `gts8pwifi_defconfig` | **uniLoader** (`ivoszbg/uniLoader`) | GitHub PR |
| `device-samsung-gts8pwifi/`, `linux-postmarketos-qcom-sm8450/` | **pmaports** | GitLab MR, `device/testing/` |

They upstream at different speeds. The DTS is the long pole (kernel review is
strict); the pmaports and uniLoader pieces can go much sooner.

## 2. Versioning

**pmaports packages** use Alpine `APKBUILD` conventions:
- `pkgver` tracks the *upstream* thing (kernel version, e.g. `6.13_rc3`), never our
  own changes.
- `pkgrel` increments on **every** rebuild whose output changes. This is not
  cosmetic — pmbootstrap resolves the highest `pkgver-pkgrel` from its package cache,
  so forgetting to bump means **your new build is silently ignored and a stale apk is
  installed instead**. We hit exactly that this session.
- After editing any `source=` file, run `pmbootstrap checksum <pkg>` or the build
  fails with `... is missing in checksums`.

**The kernel tree** is pinned by commit, not branch:
```sh
_commit="bf1d29fced6e156dd6090a9b6600a8c44259c114"   # sm8450-mainline/linux next-new
```
Bumping it is a deliberate act: change `_commit`, `pkgver` if the version moved,
re-checksum, rebuild, and re-test a boot. Never track a moving branch — this port
depends on subtle DT/driver behaviour and silent regressions are extremely expensive
to debug on a device with no console.

## 3. Commit conventions

Conventional commits, scoped by area:

```
feat(dts): enable UFS storage
fix(dts): correct framebuffer geometry to landscape 2800x1752
fix(boot): set stock load addresses via bootimg_custom_args
docs(boot): document the uniLoader requirement
chore(kernel): bump sm8450-mainline to <sha>
```

Scopes: `dts`, `kernel`, `device`, `uniloader`, `boot`, `docs`, `make`.

Rules that matter for this project specifically:
- **One logical change per commit.** Every fix in this port was an independent
  invisible failure; bisecting them later is only possible if they are separate.
- **Explain the symptom in the body, not just the change.** "Set framebuffer to
  2800x1752" is useless; "text rendered diagonally sheared because the touchscreen's
  max_coords is a portrait coordinate space, not the display scanout" is the thing a
  future porter searches for.

## 4. Recording hardware facts

Every hardware value in our DTS must be traceable to a source. Use a comment naming
where it came from:

```dts
/*
 * Banks copied verbatim from the stock DTB (device-facts/dt/stock-fdt.dtb).
 */
```

Acceptable sources, in descending order of trust:
1. The stock DTB (`dtc -I dtb -O dts`) — authoritative for *this* hardware.
2. The downstream Samsung kernel source — authoritative for driver behaviour.
3. Mainline `sm8450.dtsi` / another mainline SM8450 device (e.g. `sm8450-hdk.dts`)
   — authoritative for the *mainline* way to express it.
4. A sibling device (`sm8450-samsung-r0q.dts`) — a starting skeleton, **not**
   authoritative: r0q omits UFS entirely and its panel geometry is not ours.

Never copy a value from a sibling device without checking it against (1).

## 5. Before submitting anywhere

- `make lint` — DTS compiles, APKBUILD/deviceinfo parse.
- Boot the device and confirm no regression (there is no CI for this; the device is
  the test suite).
- **Strip Samsung firmware and device identifiers.** No stock DTBs, no partition
  dumps, no `ro.serialno` / `ro.boot.em.did`. See `.gitignore`.

### Kernel DTS specifics
- Must build with `make dtbs_check` cleanly against the bindings.
- Drop `qcom,msm-id` / `qcom,board-id` before submitting — they are inert on the
  uniLoader path and are not accepted upstream. They exist in our tree only as a
  record of the direct-ABL experiment.
- Upstream will want the DTS to describe *hardware*, not workarounds. Our baked
  `bootargs` (a uniLoader-specific necessity) is not upstreamable as-is.

## 6. Open questions for upstream

- **`bootargs` in the DTS.** uniLoader does not set a command line, so ours lives in
  `/chosen`. Cleaner would be uniLoader learning to inject one — worth raising with
  the uniLoader maintainer rather than carrying it in a device DTS forever.
- **simplefb clocks/power-domains.** We list display clocks + `MDSS_GDSC` on the
  `simple-framebuffer` node so simpledrm holds them. r0q does not, and relies on
  `clk_ignore_unused`. Worth asking which upstream prefers.
- **`/memory` node.** Hardcoding the banks is correct for uniLoader (which does not
  patch `/memory`) but is unusual for a qcom DTS, where the bootloader normally fills
  it in. Upstream may prefer uniLoader to populate it instead.

## 7. Component pinning and the patch model

Every third-party component this port builds is **pinned**, and every local
modification takes one of exactly two shapes:

| Component | Pin | Modifications |
|---|---|---|
| kernel (sm8450-mainline) | `_commit` in the kernel APKBUILD | whole in-repo files (our drivers, DTS, config) + `*.patch` files |
| uniLoader | `UL_COMMIT` in the Makefile | whole in-repo files (board port) |
| Alpine/pmOS packages | apk repos (edge) | none — metapackages compose, never fork |

**Patches are generated, never hand-written.** Unified diff is an unforgiving
format — wrong context or counts can misapply silently. The workflow:

```sh
tools/mkpatch init            # pinned tree -> git repo, patch stack as commits
$EDITOR patch-work/linux-*/...
tools/mkpatch export my-fix   # git diff -> pmaports-overlay/.../my-fix.patch
```

Then describe the WHY in the patch header, add it to the APKBUILD `source=`,
and `make kernel`. Patches carry their motivation in-file because they are
also the to-drop list for the next base bump: each one should name the
upstream commit that obsoletes it, when known (both current DPU patches do).
