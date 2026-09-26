# PM Quick Tool

A lightweight, local-only Windows inspection and maintenance helper for IT
technicians. Built on Windows PowerShell 5.1 to speed up the existing technician
PM workflow: gather the workstation facts, report on their health, then enter the
relevant results into MyERP by hand.

**PM-Quick does not connect to MyERP.** There is no MyERP API, no database, no
network call and no telemetry anywhere in this project. It produces a report for
a human to read.

---

## 1. Two separate tools

This project ships **two independent tools**, split by a hard safety boundary.

| Tool | Script | Can it delete anything? |
|---|---|---|
| **PM-Quick** | `PM-Quick.bat` / `PM-Quick.ps1` | **No. Strictly read-only.** |
| **Temp-Cleaner** | `Temp-Cleaner\Temp-Cleaner.bat` / `.ps1` | Yes — TEMP and Recycle Bin only |

PM-Quick contains no deletion, no recycling, no Recycle Bin access and no
cleanup path at all. All destructive code lives in Temp-Cleaner.

> **Do not merge these back together.** The split is the safety model, not a
> packaging preference. It exists so a read-only inspection can be run on a
> machine by anyone, without an elevation prompt and without any possibility of
> data loss.

---

## 2. Project overview

PM-Quick runs on the technician's workstation and collects a read-only hardware,
system, network, storage and health inventory, then prints a report. It
deliberately does not change system configuration.

What it does:

- Reports PC name, manufacturer, model, BIOS serial, device type, Windows
  edition/build, architecture, logged-on user and uptime
- Reports CPU, core/thread counts and clocks
- Reports total RAM, form factor, speed and per-module detail
- Reports GPU name, VRAM and driver version
- Reports motherboard and physical disk hardware
- Reports every network adapter with its state, type, MAC and addresses, and
  never auto-selects a single "the" address
- Reports per-drive total, used and free space with a **free-space percentage**
- Reports disk SMART status and SSD wear where the hardware exposes it
- Runs health checks: battery, TPM, Secure Boot/VBS, pending reboot, disk space,
  disk health, SSD wear
- Prints a technician summary with recommended actions
- Optionally writes the same data to a **local** JSON file

What it does not do:

- Delete, move or rename any file
- Read, enumerate or empty the Recycle Bin
- No MyERP integration of any kind
- No registry, service, network or Windows Update changes
- No outbound network traffic, cloud services or analytics
- No third-party dependencies beyond Windows and .NET Framework itself

---

## 3. Current workflow

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
System / Hardware / Network / Performance /
Storage / SSD / Health / Report
    |
    v
PM-Quick prints report + summary + recommended actions
    |
    v
Technician reviews result
    |
    v
Technician enters relevant result into MyERP
```

PM-Quick produces the material. The MyERP entry stays a manual, human step.

---

## 4. Requirements

| Requirement | Detail |
|---|---|
| Operating system | Windows 10 or Windows 11 |
| PowerShell | Windows PowerShell **5.1** (Desktop edition) |
| Privileges | PM-Quick: optional, but Administrator is recommended. Temp-Cleaner: **required** |
| Dependencies | None to install — see below |

Everything used ships with Windows:

| Dependency | Used for | Provided by |
|---|---|---|
| `Get-CimInstance` | system, hardware, OS, network, SMART, storage, TPM, VBS | `CimCmdlets` (built in) |
| `Get-Counter` | CPU sampling | `Microsoft.PowerShell.Diagnostics` (built in) |
| `Get-Volume`, `Get-Partition`, `Get-Disk`, `Get-PhysicalDisk`, `Get-StorageReliabilityCounter` | storage and SSD inventory | `Storage` (built in) |
| `Microsoft.VisualBasic` assembly | Recycle Bin send and permanent purge — **Temp-Cleaner only** | .NET Framework (built in) |
| `Shell.Application` COM object | Recycle Bin enumeration and source classification — **Temp-Cleaner only** | Windows shell (built in) |

**PowerShell 7 has not been validated.** Do not assume `pwsh` compatibility.

---

## 5. Running PM-Quick

Double-click `PM-Quick.bat`. The launcher **always elevates to Administrator**,
so a UAC prompt is expected every run. Elevation is not cosmetic: TPM state,
disk SMART and some firmware values are only readable as Administrator, and a
non-elevated run reports them as `N/A` rather than guessing.

From a PowerShell window you can bypass the launcher and call the script
directly. This does **not** elevate:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File .\PM-Quick.ps1
```

`ExecutionPolicy Bypass` is scoped to that one process; it does not change the
machine or user execution policy.

Anything unreadable is reported as `N/A` or `Unknown` — never guessed.

### Collection progress

Collection runs in six numbered steps and reports progress while it works:

```text
Step 1/6 [##----------------]  17%  System identity            0.2s
...
Step 6/6 [####################] 100%  Health checks             1.1s

Collection finished in 15.0s
```

In an interactive console the bar redraws in place on a single line. When output
is redirected — piped to a file, or captured by a test harness — the same
progress is emitted as plain lines with no ANSI escape codes, so logs stay
readable. Collection warnings are buffered and printed after the summary rather
than interleaved with the progress bar.

### Optional local JSON export

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File .\PM-Quick.ps1 -Json report.json
```

The file is written to `output\report.json` inside the project. It is written
locally and **nowhere else**: no upload, no API, no telemetry. The `output\`
directory is git-ignored. This is the only path PM-Quick will ever write to.

The closing summary stays short, because a wall of prose in the closing block
reads as noise. The no-change statement is always there; the middle line is the
only thing that varies:

```text
  ========================================
  Nothing was changed, deleted or uploaded.
  Saved: D:\myProjects\PM-Quick\output\report.json   <- only when a file was written
  For TEMP/Recycle Bin cleanup run Temp-Cleaner.bat
  ========================================
```

| Outcome | Middle line |
|---|---|
| Plain run, or the export offer declined | *(absent)* |
| Report saved | `Saved: <full path>` |
| Export failed | `Export failed - no report file was written.` |

Creating a new report does not change any *existing* file, so the no-change
statement remains true; naming the saved path is what keeps it honest.

### End-of-run export offer

After the report, PM-Quick asks whether to save a local JSON copy:

```text
  Save this report as a local JSON file? [Y/N]
  Press Enter to skip. Nothing is written unless you type Y.
  Export JSON? [Y/N]
```

The consent rule is the same one the cleaner's destructive gate uses: **only a
literal `Y`/`y` or `N`/`n` is an answer.** A bare `Enter` is not an answer. If you
lean on the key it re-prompts and nothing is written — an accidental keystroke
cannot create a file.

| Input | Result |
|---|---|
| `y` / `Y` | save the report |
| `n` / `N` | skip, nothing written |
| `Enter`, space, `Enter` again | re-prompt, nothing written |
| `yes`, `YES`, `Y n`, `maybe` | re-prompt, nothing written |
| Ctrl+C or window closed | declines quietly, nothing written, no error |
| input exhausted (EOF) | declines, nothing written |

Answering `Y` then prompts for a file name, defaulting to a timestamped name.
A name containing a path separator or `..` is refused rather than allowed to
redirect the write outside `output\`.

The offer is skipped entirely when there is no interactive console — piped
output, redirected stdin, or the validation harness — so nothing can ever block
waiting for an answer that will never come. Use `-NoExportPrompt` to suppress it
explicitly.

---

## 6. Modules

| Module | Public function | Purpose |
|---|---|---|
| `modules/System.ps1` | `Get-PMSystemInfo`, `Get-PMDeviceType` | PC name, manufacturer, model, BIOS serial, Windows edition/build, architecture, user, uptime; Desktop vs Laptop from chassis/PCSystemType/battery evidence |
| `modules/Hardware.ps1` | `Get-PMHardwareInfo` | CPU, RAM (total, slots, speed, form factor, per-module), GPU, motherboard, physical disks |
| `modules/Network.ps1` | `Get-PMNetworkInfo` | Every adapter with type, state, MAC, DHCP, speed, addresses; gateway and DNS |
| `modules/Performance.ps1` | `Get-PMPerformanceSnapshot` | Short CPU sample plus an instant memory reading |
| `modules/Storage.ps1` | `Get-PMStorageInfo` | Per-drive total/used/free and free percentage, physical disk SMART status, low-space detection |
| `modules/SSD.ps1` | `Get-PMSSDHealth` | SSD health, wear, estimated life, temperature; SMART fallback |
| `modules/Health.ps1` | `Get-PMHealthCheck` | Battery, TPM, Secure Boot/VBS, pending reboot, disk space, disk health, SSD wear |
| `modules/Report.ps1` | `Get-PMSummaryText`, `Get-PMRecommendations`, `Export-PMInspectionJson` | Console rendering, technician summary, recommendations, local JSON |

All eight modules are strictly read-only.

---

## 7. Running Temp-Cleaner

Double-click `Temp-Cleaner\Temp-Cleaner.bat`. It self-elevates, shows a preview,
and asks `Proceed with cleanup? [Y/N]`.

```text
Temp-Cleaner.bat
    -> net session probe
    -> if not elevated: Start-Process -Verb RunAs (re-launches .bat)
    -> powershell -File "%~dp0Temp-Cleaner.ps1"
    -> pause
```

### Confirmation

| Input | Result |
|---|---|
| `Y` / `y` | cleanup runs |
| `N` / `n` | cleanup is skipped |
| Enter (empty) | does not proceed, re-prompts |
| whitespace only | does not proceed, re-prompts |
| anything else | does not proceed, re-prompts |

Only an explicit `Y` or `y` authorises cleanup. Enter, whitespace and any other
input re-prompt instead of defaulting to cleanup, so a stray or buffered
keystroke — including a bare Enter pressed while reading an earlier section —
can never authorise a destructive action.

---

## 8. Cleanup safety model

Cleanup runs in three ordered stages. Each stage only ever removes files whose
original source has been proven to be a TEMP directory.

```text
Stage A
User TEMP
    |
    v
Permanent delete

Stage B
Windows TEMP
    |
    v
Permanent delete

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

Stages A and B never touch the Recycle Bin. They used to recycle each file
first, but that was not a safety net: Stage C purges TEMP-origin items in the
same run, so the Recycle Bin never really kept them. It only cost time, because
moving a file into the Recycle Bin spends about a second discovering that a file
held open by another process cannot be moved, while deleting it outright fails in
about twenty milliseconds. It also made the preview's purge count wrong, since
the run kept adding the very items the preview had already counted.

Stage C is the only stage that reads the Recycle Bin, and it purges only items
whose recorded original path lies inside a known TEMP root.

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
  clear or shell-empty the Recycle Bin.
- **A failed delete leaves the file alone.** If a file cannot be removed it is
  counted as skipped and left in place. Nothing escalates a failure into a
  broader or more aggressive delete.
- **Root paths must be absolute.** `Get-TempTreeSafe` refuses a non-absolute
  root outright. Windows strips trailing spaces from a path, so a
  whitespace-only root such as `"   "` silently collapses to the current
  directory; for a destructive caller that would mean collecting the wrong
  tree. Every legitimate root (`$env:TEMP`, `%SystemRoot%\Temp`) is absolute, so
  this refuses nothing real.
- **Confirmation is required.** Nothing is deleted unless the technician types an
  explicit `Y` or `y`.

Permanent deletion is confined to a single guarded helper that refuses any path
outside the Recycle Bin, and it is reached only from Stage C for items already
classified as TEMP-origin. Do not relax that guard.

---

## 9. Reporting

A cleanup run prints a summary line per location, then a detailed report.

```text
=== PM CLEANUP ===

USER TEMP
  Files found       : 4
  Deleted           : 3
  Skipped           : 1
  Before            : 32 KB
  After             : 8 KB

WINDOWS TEMP
  Files found       : 3
  Deleted           : 1
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
- **Deleted** — files deleted outright
- **Skipped** — files that could not be processed, for example because they are locked
- **Before / After** — measured size of that location, before and after
- **TEMP-origin found** — Recycle Bin items whose source was proven to be TEMP
- **Purged** — TEMP-origin items permanently removed in Stage C
- **Left untouched** — non-TEMP Recycle Bin items deliberately preserved
- **Total cleaned** — combined reclaimed size

When anything is skipped, a `SKIPPED` section is appended. It leads with a
per-stage summary taken from the authoritative `Skipped` counters, then adds one
line per kind of reason:

```text
SKIPPED
  User TEMP         : 13 file(s) left untouched.
  Windows TEMP      : 1 file(s) left untouched.
    12 of those were held open by a running process. They are swept on the next run or after a restart.
    2 could not be removed (access denied).
```

Individual file names are not listed. A TEMP file that cannot be removed is not
something that can be chased one at a time, and the names were the noisiest part
of the output. The underlying exception text is still captured per file and
carried in the result object, so it is available to anything consuming the
result; only the console rendering was removed.

Reasons are derived from the exception text and counted in `SkipReasons`. Two
buckets matter:

- `in-use` - a running process holds the file. Expected, needs no action, and
  cleared by the next run or a restart.
- `denied` and everything else - the file could not be removed for some reason
  that may need a human.

`denied` is deliberately **not** folded into the `in-use` bucket. Doing so would
read more tidily and would be false: a permission problem does not clear on the
next run or after a restart, which is exactly what the lock line tells the
operator.

The `Skipped / Failed` line is deliberately not called "locked": that single
counter also covers failed deletions and failed purges.

---

## 10. DryRun

`Invoke-PMCleanup` supports a `-DryRun` switch. In dry-run mode Temp-Cleaner
performs the full safe traversal and reports exactly what it *would* do, but:

- no file is deleted
- no file is permanently deleted
- no Recycle Bin item is purged
- the report is titled `=== PM CLEANUP (DRY RUN) ===` and states
  `No files were deleted.`

Invoke it directly against the script:

```powershell
. ".\Temp-Cleaner\Temp-Cleaner.ps1"
Invoke-PMCleanup -DryRun
```

The script is dot-sourceable without running the interactive flow, because the
entry point is guarded by an `if ($MyInvocation.InvocationName -ne '.')` check.

---

## 11. Limitations

Real constraints discovered during development.

- **Recycle Bin quota affects items the user deleted, not this tool.** Temp-Cleaner
  no longer sends anything to the Recycle Bin, so it cannot lose a file to the
  operating system's quota or volume limit. Stage C only ever *removes* existing
  items, and only TEMP-origin ones. Items the technician deleted by hand remain
  subject to normal Windows Recycle Bin behaviour.
- **Locked files are never force-deleted.** Files held by running services stay
  in TEMP until released.
- **GPU VRAM is often `N/A`.** `Win32_VideoController.AdapterRAM` is a signed
  32-bit field, so a modern GPU overflows it. A negative or implausible value is
  reported as `N/A` rather than as a wrong number.
- **SSD estimated life is often `N/A`.** Many consumer SATA SSDs report
  `Wear = 0%`, meaning "not reported" rather than "brand new".
- **Disk serials are often blank** without Administrator, and are reported as
  `N/A`.
- **RAM slot count is often `N/A`.** Most desktops do not expose a physical slot
  count through WMI.
- **Device type can be `Unknown`.** It is derived from chassis, `PCSystemType` and
  battery presence, never from the PC name. The evidence is printed so a
  technician can see how the call was made.
- **Multiple IPv4 addresses are all shown.** PM-Quick does not choose one. The
  technician must confirm the correct address in MyERP.
- **Complex RAID or Storage Spaces** configurations may not map drive letters
  cleanly, so a drive may be reported without a size.
- **The cleanup preview is a sample.** Sizes are measured at preview time and
  may differ slightly by the time cleanup runs.
- **PowerShell 7 is untested.** Use Windows PowerShell 5.1.

---

## 12. Testing

Validation was run from a durable harness kept outside the repository, so no
test artefact could be committed by accident. The harness has since been
deleted, and the results below are a historical record rather than something
you can reproduce from this repository. The last full run was against v1.1.

| Suite | Scope | Result at v1.1 |
|---|---|---|
| P1a function parity | Destructive code moved from the frozen baseline unchanged | 45 pass / 0 fail |
| P1b runtime read-only | Runs PM-Quick and proves it changes nothing on disk | 45 pass / 0 fail |
| P2 sandboxed cleanup | Cleaner works, and its guards refuse bad input | 122 pass / 0 fail |
| P3 information modules | All eight modules load, collectors work, fields exist | 318 pass / 0 fail |
| P4 read-only audit | PM-Quick contains no destructive path, no duplicates | 32 pass / 0 fail |
| | **Total** | **562 pass / 0 fail** |

Two techniques are worth calling out, because they are what made those results
trustworthy rather than decorative:

- **P1b redirected `TEMP` and `TMP`** to an empty sandbox for the child process
  only. Every temporary file PM-Quick created therefore landed somewhere
  attributable, so concurrent noise from the real temp directory could not
  produce a false pass and a real leak could not hide.
- **P2 never ran the destructive engine against real user temp.**
  `Invoke-PMCleanup` has no `-Root` parameter, so it was exercised in a child
  process with a redirected temp, and the Recycle Bin round trip recorded the
  bin count before and after and restored it exactly.

**There is no automated regression net in this repository now.** Any future
change to `PM-Quick` or `Temp-Cleaner` has to be checked by hand. In
particular, nothing would automatically catch a change that weakens a deletion
guard, so re-verify the safety behaviour manually before trusting a build.

### What automation cannot cover

The UAC hand-off, the interactive in-place progress bar and the consent gate need
a physical console. The automated suites cover the non-elevated branch and the
redirected-output branch only; they are not evidence about the elevated or
interactive paths. Those were exercised by hand instead, and the split between
the two is recorded under Project status rather than claimed as automated.

---

## 13. Project status

| Area | Status |
|---|---|
| Read/write split | Complete |
| Read-only inspection modules | Complete |
| Collection progress (6 steps, console + redirected) | Complete |
| Mandatory elevation in `PM-Quick.bat` | Complete — non-elevated branch automated, UAC branch verified by hand |
| Temp-Cleaner safety code | Complete - 7 of 11 surviving functions byte-identical to the frozen baseline; the recycle round trip was removed on purpose |
| Automated validation | 562 assertions, 0 failures at v1.1. Harness since deleted, so no automated net remains |
| Real environment validation | **Partial** — see below |
| Release | v1.1 published. Gate was the physical run, and that was performed. |

The three moved functions that are **not** byte-identical were each changed on
purpose, and P1a asserts the specific markers that prove the change is the
intended one rather than an unrelated edit:

| Function | Intentional change |
|---|---|
| `Get-TempTreeSafe` | Root guard now requires a drive-qualified root. `[System.IO.Path]::IsPathRooted` returns `True` for the drive-relative form `C:`, which previously walked the entire drive. |
| `Get-DirectorySize` | Returns a real `0` for an existing-but-empty directory instead of `$null`. |
| `Invoke-PMCleanup` | Warnings use `.ToArray()`; on PowerShell 5.1 `@($list)` yields a one-element array holding the list. |

Physical execution was performed on a real desktop before v1.1 was tagged.

Verified by hand, on the target machine:

- `PM-Quick.bat` UAC elevation and the full read-only collection
- `Temp-Cleaner.bat` UAC elevation, the in-place progress bar, and the `Y`
  consent path
- permanent-delete behaviour, including a non-TEMP Recycle Bin item
  (`Naif_Muazzam_CV_MASTER-1.pdf`) surviving every run untouched
- the runtime effect of the performance fix: 56s before, 0-1s after

Not verified by hand:

- the `N` consent path and the Ctrl+C abort path
- the aggregate `SKIPPED` block as finally rendered, which was still
  automated-only at the time of tagging

This is not claimed to be production ready. The automated suite and a single
happy-path physical run are not the same as broad field use.

---

## Project structure

```text
PM-Quick/
|-- PM-Quick.bat              launcher (read-only tool)
|-- PM-Quick.ps1              main read-only script: collect, report, summarise
|-- README.md                 this file
|-- .gitignore
|-- output/                   local JSON exports (git-ignored)
|-- modules/
|   |-- System.ps1            identity, Windows build, uptime, device type
|   |-- Hardware.ps1          CPU, RAM, GPU, motherboard, disk hardware
|   |-- Network.ps1           adapters, addresses, gateway, DNS
|   |-- Performance.ps1       CPU and memory snapshot
|   |-- Storage.ps1           drives, free %, disk SMART status
|   |-- SSD.ps1               SSD health, wear, SMART fallback
|   |-- Health.ps1            battery, TPM, Secure Boot, WU, disks
|   `-- Report.ps1            rendering, summary, recommendations, JSON
`-- Temp-Cleaner/
    |-- Temp-Cleaner.bat      launcher, self-elevates to Administrator
    `-- Temp-Cleaner.ps1      the only script that deletes anything
```

## Safety and scope

- Local-only tools. Nothing is sent anywhere.
- PM-Quick never deletes, recycles, or touches the Recycle Bin.
- No registry, service, network or Windows Update modification.
- No telemetry, cloud, API or database functionality.
- No external dependencies beyond built-in Windows and .NET Framework.
- No product key, credential or software serial is collected.
- Release version is tracked by Git, not by a version variable in the code.
