# PM Quick Tool

A lightweight, local-only Windows preventive maintenance helper for IT
technicians. Built on Windows PowerShell 5.1 to speed up the existing technician
PM workflow: gather the workstation facts, clean TEMP safely, then enter the
relevant results into MyERP by hand.

**PM-Quick does not connect to MyERP.** There is no MyERP API, no database, no
network call and no telemetry anywhere in this project. It produces a report for
a human to read.

---

## 1. Project overview

PM-Quick runs on the technician's workstation, collects read-only hardware and
system inventory, and optionally performs a guarded TEMP cleanup. It is a
reporting and cleanup aid — it deliberately does not change system
configuration.

What it does:

- Reports PC name, BIOS serial, Windows edition/build and logged-on user
- Reports every IPv4 address on active physical adapters, with **no**
  auto-selection
- Samples CPU and memory usage
- Reports per-drive capacity, free space, media type and internal/external
- Reports SSD health and estimated life where the hardware exposes reliable data
- Previews and optionally performs TEMP cleanup with Recycle Bin source
  validation

What it does not do:

- No MyERP integration of any kind
- No registry, service, network or Windows Update changes
- No outbound network traffic, cloud services or analytics
- No third-party dependencies beyond Windows and .NET Framework itself

---

## 2. Current workflow

```text
Technician
    |
    v
PM-Quick.bat
    |
    v
PM-Quick.ps1
    |
    v
System / Network / Performance /
Storage / SSD / Cleanup
    |
    v
Technician reviews result
    |
    v
Technician enters relevant result into MyERP
```

PM-Quick produces the material. The MyERP entry stays a manual, human step.

---

## 3. Requirements

| Requirement | Detail |
|---|---|
| Operating system | Windows 10 or Windows 11 |
| PowerShell | Windows PowerShell **5.1** (Desktop edition) |
| Privileges | Administrator. `PM-Quick.bat` self-elevates; `PM-Quick.ps1` declares `#Requires -RunAsAdministrator` |
| Dependencies | None to install — see below |

Everything PM-Quick uses ships with Windows:

| Dependency | Used for | Provided by |
|---|---|---|
| `Get-CimInstance` | system, OS, network fallback, SMART, storage fallback | `CimCmdlets` (built in) |
| `Get-NetAdapter`, `Get-NetIPAddress` | adapter and IPv4 enumeration | `NetAdapter`, `NetTCPIP` (built in) |
| `Get-Counter` | CPU sampling | `Microsoft.PowerShell.Diagnostics` (built in) |
| `Get-Volume`, `Get-Partition`, `Get-Disk`, `Get-PhysicalDisk`, `Get-StorageReliabilityCounter` | storage and SSD inventory | `Storage` (built in) |
| `Microsoft.VisualBasic` assembly | Recycle Bin send and permanent purge | .NET Framework (built in) |
| `Shell.Application` COM object | Recycle Bin enumeration and source classification | Windows shell (built in) |

**PowerShell 7 has not been validated.** Do not assume `pwsh` compatibility.

---

## 4. Running PM-Quick

Double-click `PM-Quick.bat`. It probes for elevation, re-launches itself elevated
if needed, and then runs the main script:

```text
PM-Quick.bat
    -> net session probe
    -> if not elevated: powershell Start-Process -Verb RunAs (re-launches .bat)
    -> powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0PM-Quick.ps1"
    -> pause
```

The equivalent direct invocation, from an already-elevated PowerShell window:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File .\PM-Quick.ps1
```

`ExecutionPolicy Bypass` is scoped to that one process; it does not change the
machine or user execution policy.

The script collects all sections first, shows a cleanup preview, then asks
`Proceed with cleanup? [Y/N]`. Answering `N` deletes nothing.

Cleanup confirmation requires an explicit `Y` or `y`. Empty or invalid input
does not proceed with cleanup.

| Input | Result |
|---|---|
| `Y` / `y` | cleanup runs |
| `N` / `n` | cleanup is skipped |
| Enter (empty) | does not proceed, re-prompts |
| whitespace only | does not proceed, re-prompts |
| anything else | does not proceed, re-prompts |

An accidental or buffered keystroke - including a stray Enter pressed while
reading an earlier section - can therefore never authorise a destructive
cleanup. Invalid input prints `Please enter Y or N.` and asks again.

---

## 5. Modules

| Module | Public function | Purpose |
|---|---|---|
| `modules/System.ps1` | `Get-PMSystemInfo` | PC name, BIOS serial, Windows edition/build, logged-on user |
| `modules/Network.ps1` | `Get-PMNetworkInfo` | IPv4 addresses on up, non-virtual adapters; CIM fallback |
| `modules/Performance.ps1` | `Get-PMPerformanceSnapshot` | Short CPU sample plus an instant memory reading |
| `modules/Storage.ps1` | `Get-PMStorageInfo` | Per-drive total/free size, media type, internal vs external |
| `modules/SSD.ps1` | `Get-PMSSDHealth` | SSD health, wear, estimated life, temperature; SMART fallback |
| `modules/Cleanup.ps1` | `Invoke-PMCleanup`, `Get-TempCleanupEstimate`, and helpers | TEMP cleanup, Recycle Bin source validation, reporting |

The five information modules are strictly read-only. `Cleanup.ps1` is the only
module that deletes anything.

---

## 6. Cleanup safety model

Cleanup runs in three ordered stages. Each stage only ever removes files whose
original source has been proven to be a TEMP directory.

```text
Stage A
User TEMP
    |
    v
Recycle Bin

Stage B
Windows TEMP
    |
    v
Recycle Bin

Stage C
Recycle Bin
    |
    v
Classify original source
    |
    v
Only TEMP-origin items
    |
    v
Permanent purge
```

**Stage A and B** recycle TEMP files rather than deleting them, so a mistake is
recoverable from the Recycle Bin. **Stage C** then purges only the Recycle Bin
items whose recorded original path lies inside a known TEMP root.

Guarantees:

- **Non-TEMP Recycle Bin items are untouched.** They are reported under
  `Left untouched` and never purged.
- **Unknown source is not treated as TEMP.** If a Recycle Bin item's original
  path cannot be read or resolved, it is excluded from the purge.
- **Locked files are left untouched.** A file held by a running process is
  counted as skipped and left in place.
- **Reparse points and junctions are skipped.** Traversal never descends into a
  junction or symlink, so cleanup cannot escape the TEMP tree or delete through
  a link.
- **The Recycle Bin is never emptied wholesale.** There is no call to empty,
  clear or shell-empties the Recycle Bin.
- **No permanent-delete fallback.** If recycling a file fails, the file stays
  where it is. There is no path that escalates a recycle failure into a
  permanent delete.
- **Confirmation is required.** Nothing is deleted unless the technician types an
  explicit `Y` or `y`. Enter, whitespace, and any other input re-prompt instead
  of defaulting to cleanup, so stray or buffered keystrokes can never authorise a
  destructive action.

Permanent deletion is confined to a single guarded helper that refuses any path
outside the Recycle Bin, and it is reached only from Stage C for items already
classified as TEMP-origin. Do not relax that guard.

---

## 7. Reporting

A cleanup run prints a summary line per location, then a detailed report.

```text
=== PM CLEANUP ===

USER TEMP
  Files found       : 4
  Recycled          : 3
  Skipped           : 1
  Before            : 32 KB
  After             : 8 KB

WINDOWS TEMP
  Files found       : 3
  Recycled          : 1
  Skipped           : 2
  Before            : 286.6 KB
  After             : 278.6 KB

RECYCLE BIN
  TEMP-origin found : 5
  Purged            : 5
  Skipped           : 0
  Left untouched    : 9 (non-TEMP source)

RESULT
  Total cleaned     : 68 KB
```

- **Files found** — files discovered in that TEMP location
- **Recycled** — files successfully sent to the Recycle Bin
- **Skipped** — files that could not be processed, for example because they are locked
- **Before / After** — measured size of that location, before and after
- **TEMP-origin found** — Recycle Bin items whose source was proven to be TEMP
- **Purged** — TEMP-origin items permanently removed in Stage C
- **Left untouched** — non-TEMP Recycle Bin items deliberately preserved
- **Total cleaned** — combined reclaimed size

When anything fails, a `WARNINGS` section is appended. It leads with a per-stage
summary taken from the authoritative `Skipped` counters, then lists the
individual failures:

```text
WARNINGS
  User TEMP         : 12 file(s) left untouched.
  Windows TEMP      : 1 file(s) left untouched.

    Details:
    [WARN] User TEMP: 'file1.tmp' - The process cannot access the file because it is being used by another process
    [WARN] User TEMP: 'file2.tmp' - Access is denied
    [WARN] ... and 7 more failure(s) not listed.
```

Each detail line names the stage and the file, and quotes the real operating
system error verbatim. PM-Quick does not guess a reason category, because the
recycle and purge APIs cannot reliably distinguish a locked file from a
permission failure. Identical reasons are grouped into the stage summary rather
than repeated, so a workstation with dozens of skipped files stays readable.

The detail list is capped at 15 notes plus an overflow marker, so a busy
workstation cannot flood the console. The stage summary and the per-stage
`Skipped` counters always report the true totals, so nothing is hidden by the
cap.

The `Skipped / Failed` line is deliberately not called "locked": that single
counter also covers failed recycles and failed purges.

---

## 8. DryRun

`Invoke-PMCleanup` supports a `-DryRun` switch. In dry-run mode PM-Quick performs
the full safe traversal and reports exactly what it *would* do, but:

- no file is recycled
- no file is permanently deleted
- no Recycle Bin item is purged
- the report is titled `=== PM CLEANUP (DRY RUN) ===` and states
  `No files were recycled or permanently deleted.`

Invoke it directly against the module:

```powershell
. ".\modules\Cleanup.ps1"
Invoke-PMCleanup -DryRun
```

The interactive `PM-Quick.bat` flow previews sizes and asks for confirmation; it
does not currently expose a DryRun menu entry.

---

## 9. Limitations

Real constraints discovered during development.

- **Recycle Bin quota.** Windows may permanently delete a file at the moment it
  is sent to the Recycle Bin if that file exceeds the Recycle Bin or volume
  quota. PM-Quick does not override operating-system Recycle Bin policy and
  cannot guarantee that any individual file remains recoverable. Recycling in
  Stage A is a safety step, not a backup.
- **Locked files are never force-deleted.** Files held by running services stay
  in TEMP until released.
- **SSD estimated life is often `N/A`.** Many consumer SATA SSDs report
  `Wear = 0%`, meaning "not reported" rather than "brand new". PM-Quick shows
  `N/A` rather than a misleading figure.
- **Virtual adapter filtering is name-based.** An adapter with a non-standard
  name may not be filtered out, and may appear in the IPv4 list.
- **Multiple IPv4 addresses are all shown.** PM-Quick does not choose one. The
  technician must confirm the correct address in MyERP.
- **Complex RAID or Storage Spaces** configurations may not map drive letters
  cleanly, so a drive may be reported without a size or media type.
- **The cleanup preview is a sample.** Sizes are measured at preview time and
  may differ slightly by the time cleanup runs.
- **PowerShell 7 is untested.** Use Windows PowerShell 5.1.

---

## 10. Testing

### Automated / local validation — complete

Executed on a Windows 10 Pro 19045 development host with Windows PowerShell
5.1.19041.6456. All suites run outside the repository so no test artefact can be
committed by accident.

| Suite | Result |
|---|---|
| P1 safety regression | **68 PASS / 0 FAIL** |
| P2 result/reporting contract | **110 PASS / 0 FAIL** |
| P3 UX, warnings, confirmation and DryRun | **113 PASS / 0 FAIL** |
| P4 information modules | **57 PASS / 0 FAIL** |
| PowerShell 5.1 parser, all 7 scripts | **0 parse errors** |
| Module load, all 6 modules | **6/6 clean** |
| P1 safety functions vs `HEAD` | **7/7 byte-identical** |
| Forbidden-pattern safety audit | **0 findings** |

Coverage highlights: the `...\Temp` vs `...\TempEvil` prefix trap, `.`/`..`
resolution, malformed and null-byte paths, a real NTFS junction with a canary
file, a genuinely locked file, non-TEMP Recycle Bin survival, Stage A → B → C
ordering, result-property types and ordering, the warning cap, and DryRun
inertness. The five information modules are proven read-only by static scan: no
mutating cmdlet, no network call, no registry or service change.

Full detail, including the safety audit, is in
[`docs/P4-VALIDATION.md`](docs/P4-VALIDATION.md).

### Real Sigma environment validation — pending

**Not yet performed.** The automated results above come from a development host,
not the Sigma technician PC, and specifically do not cover:

- launching through `PM-Quick.bat` and the UAC elevation hand-off
- the interactive console output and the Y/N confirmation gate
- behaviour in a genuinely elevated session
- **Windows 11** — the development host runs Windows 10
- the Sigma PC's physical storage hardware and SMART data

The step-by-step procedure and a sign-off block are in
[`docs/P4-VALIDATION.md`](docs/P4-VALIDATION.md), Section 5.

---

## 11. Project status

```text
Core implementation complete.
Automated safety/regression validation complete.
Real-world Sigma validation PENDING.
```

| Area | Status |
|---|---|
| Core implementation | Complete |
| Automated safety and regression validation | Complete — 348 assertions, 0 failures |
| Safety audit | Complete — 0 findings |
| Documentation | Complete |
| Real Sigma environment validation | **Pending** — requires physical execution |
| `v1.0.0` release | **Blocked** until Sigma validation is signed off |

This is not claimed to be production ready. The release gate is the Sigma
validation sign-off, not the automated suite.

---

## Project structure

```text
PM-Quick/
|-- PM-Quick.bat              launcher, self-elevates to Administrator
|-- PM-Quick.ps1              main script: collect, preview, confirm, report
|-- README.md                 this file
|-- .gitignore
|-- docs/
|   `-- P4-VALIDATION.md      validation record and Sigma sign-off sheet
`-- modules/
    |-- System.ps1            PC name, serial, Windows, user
    |-- Network.ps1           IPv4 detection, virtual adapter filtering
    |-- Performance.ps1       CPU and memory snapshot
    |-- Storage.ps1           drive detection, SSD/HDD, internal/external
    |-- SSD.ps1               SSD health, wear, SMART fallback
    `-- Cleanup.ps1           TEMP cleanup, Recycle Bin validation, reporting
```

## Safety and scope

- Local-only tool. Nothing is sent anywhere.
- No registry, service, network or Windows Update modification.
- No telemetry, cloud, API or database functionality.
- No external dependencies beyond built-in Windows and .NET Framework.
- Release version is tracked by Git, not by a version variable in the code.
