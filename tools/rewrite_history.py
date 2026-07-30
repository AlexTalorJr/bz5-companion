#!/usr/bin/env python3
"""Rewrite this repository's history once, for going public.

Two jobs in one pass, because both need the same rewrite and doing them
separately would mean two force-pushes and two CI builds.

JOB 1 - language. Sixty-three commit messages were written in Russian, so the
published history read in two languages. They become English; --check prints
the totals for the branch it is run on rather than trusting this paragraph.

JOB 2 - purge the parsed feature catalogue. Deleting the file at the tip was
not enough: a deletion commit leaves the blob reachable from every earlier
commit and from all 98 build-N tags, so the 615863-byte dump extracted from
the vehicle software stayed fully downloadable from the public repository.
Removing it from the published history means rewriting every ref that can
reach it, tags included.

Three mechanisms, deliberately different:

  FULL_MESSAGES  twenty-five commits whose message was substantially or
                 entirely Russian. Each gets a condensed English message
                 that keeps the problem statement, the numbered sections,
                 the gate results and the open items, and drops internal
                 narrative that has no business in a public log.

  TOKEN_SUBS     short phrases replaced in place across every message:
                 collaborator nicknames, and Russian UI labels quoted
                 inside otherwise-English messages. A quoted UI label is
                 replaced by an English gloss rather than a translation,
                 because the literal in the code is still Russian and the
                 log must not claim otherwise.

  LINE_SUBS      whole lines replaced one for one, for commits whose
                 message is English except for a handful of sentences.

Commits are keyed by abbreviated SHA and resolved with `git rev-parse` at
run time, which fails loudly on an ambiguous or missing prefix.

Trees are never touched - only messages change. Commit SHAs do change, and
so does every descendant, which is why this runs exactly once.

Usage:

    python3 tools/anglicize_history.py --check   # report only, no writes
    python3 tools/anglicize_history.py --run     # rewrite refs/heads/main

--run rewrites EVERY ref, tags included. That is a change of plan and the
reason is job 2: leaving the 98 build-N tags on their old commits would leave
the catalogue downloadable, which defeats the point. Tags keep their names and
move to the rewritten commits, so the GitHub Releases attached to those names -
this app's only delivery channel - keep their APK assets. That last part is the
one claim here I could not verify offline; check one Release afterwards.

Rewriting history does not guarantee the data is unreachable. Objects can
survive in clones and forks, and on GitHub they stay addressable by SHA in
cached views until the platform garbage-collects. If that matters, open a
support ticket after the force-push and ask for a GC.

Because the purge prunes the blob locally as well, --run refuses to touch
anything until it is shown a copy of the catalogue outside this repository:

    git show HEAD:docs/bz5_feature_catalog.csv > ~/bz5_feature_catalog.csv
    python3 tools/rewrite_history.py --run --backup ~/bz5_feature_catalog.csv

Afterwards:

    git push --force origin main
    git push --force --tags

Requires git-filter-repo (pip install git-filter-repo).
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys

CYRILLIC = re.compile(r'[\u0400-\u04FF]')

# Paths purged from every ref. Both entries are the same blob.
PURGE_PATHS = [
    'docs/bz5_feature_catalog.csv',
    'bz5_companion_native_scaffold/docs/bz5_feature_catalog.csv',
]
CATALOGUE_SHA256 = ('80fc73ff91316177ab9e3a9a40ab3aba'
                    '3e5fef88bd05eea6b4e70f4f89394593')
CATALOGUE_BYTES = 615863

# ---------------------------------------------------------------------------
# FULL_MESSAGES - commits whose message is replaced whole.
# ---------------------------------------------------------------------------

FULL_MESSAGES = {}

FULL_MESSAGES['4e63f7c9'] = """\
v0.1.75+174 - field debts from 29.07

The autostart bridge is confirmed in the field: 8 `bridged:` lines, zero
`resurrected:`, zero `destroy:`. The chain FIRED -> ALARM_SCHEDULED
exact=yes -> OK -> born: -> bridged: reproduced across five wakeups with a
5-9 s delay against a nominal 250 ms, and the negative verdict of +169
held for a fourth time. But the field also disproved two comments and
exposed two gaps in the instruments.

1. The marker travels on a second channel. The export ZIP arrived
   truncated twice, both times on a 32 KiB boundary - the signature of an
   unflushed buffer - and the marker was riding only inside it, the public
   Downloads path being dead. The diag dump arrived intact every time
   because it is small and written separately. AutostartMarker.read() now
   returns up to a 64 KB tail via RandomAccessFile, seeking instead of
   trimming after the fact: the log is append-only and never pruned
   (~96 B per line, heartbeat every 5 min, ~27 KB/day, ~10 MB/year), so
   readText() would pull the whole file into memory on the main thread.
   The cut is aligned to a line boundary because a raw offset can land
   inside a UTF-8 sequence. A tile in Advanced writes the tail into the
   diag dump, with a double-tap latch.

2. ident() on every receiver line. Since +171 the AutostartMarker
   docstring claimed that a matching process tag proved receiver and
   service shared one process - while receiver lines never printed the tag
   at all. Promise without evidence, the same class of defect as the "boot
   path is a proven wall" note. They print it now.

3. The false "duplicates cannot happen" claim is withdrawn. Rescheduling
   replaces a pending alarm only inside the window before it fires; at a
   5-9 s delay with broadcasts spread over 9-19 s the first one gets
   through, which is why there are 8 bridged: against 6 born:. Harmless,
   but the justification has to be that the repeat is idempotent, not that
   it never happens - the first is checkable and true, the second was a
   guess.

4. The A1 identity check became a tool, tools/atlas_a1_check.py. It had
   lived in my head and raised a false alarm at 120 s while the broken
   part was the check itself: fe/fd/ft live in process memory, so after a
   restart the ledger knows nothing about time already flushed into
   snapshots while the trip counter keeps counting it. Keyed on the count
   of flushed snapshots it reproduces all four observations: 4 exact,
   2 skipped, 0 violated. Session-window divergence cannot be the
   discriminator - windows diverge even where the identity holds to
   8.5e-14. The single-dump limitation is named in the file.

Gates: 7/7 - OK - 22/0/0 - 490 PASS / 1 WARN (G3) / 0 FAIL,
dart_balance 74/74. New era BK (5 gates), 39 mutations, every gate fails
when its own subject is reverted.

Four defects in our own gates, caught by mutation and by the run: a check
forbade a phrase that its own correction quoted, which is literally the
BJ5 lesson from one patch earlier; BH4 cut its block at the first '}' and
section 2 added a string template to that line, so the brace inside the
template truncated the region before the return and the gate failed on
correct code; a clause referenced an undeclared variable, so once the
first condition began to pass the run died with NameError instead of FAIL,
the +170 lesson in a third disguise; BK2 was vacuous, matching a parameter
name rather than the boundary itself, and BK3 pinned exactly six log
records, which would break the build on any future line. Pin the relation,
not the count.

OPEN ITEM: the log is never pruned. Seeking fixes reading, but the file
keeps growing ~10 MB/year in filesDir. Rotation is deliberately absent
here - the file is also written from boot context on the main thread, and
rewriting a multi-megabyte file at that moment is the same class of risk
this patch removes. It needs its own lock.
"""

FULL_MESSAGES['8bc46a3a'] = """\
v0.1.74+173 - autostart switch, plus fixes from the architecture review

The review of +171/+172 found a mechanism that arms itself quietly and
cannot be turned off at all.

`disarm` had sat in the MethodChannel since +155 and was NEVER called from
Dart - dead code. While autostart rested on START_STICKY that went
unpunished, because switching off happened by itself: the process died and
was not resurrected. With the +171 bridge the service comes up on EVERY
head-unit wakeup, and nothing short of uninstalling the app could stop it.

1. The switch. A SwitchListTile in Settings -> Advanced, head unit only -
   on a phone autostart is never armed, and a toggle that provably does
   nothing is the same dishonesty as the Measurements tab on a phone. It
   lives under Advanced rather than at the top because the bridge is not
   yet proven in the field, and surfacing control of an unproven mechanism
   would be premature.

   One `armed` flag is not enough for a switch. It means "the receiver may
   act", and its absence means "not armed yet", not "the owner said no".
   Without telling those apart the next app launch would silently re-arm,
   since attach calls arm on every head-unit start. Hence a second key,
   `opt_out`, three states and one transaction: armed=false/optOut=false
   means undecided, arm by default; armed=true/optOut=false means the
   owner turned it on; armed=false/optOut=true means the owner turned it
   off, leave it alone. The truth lives once, on the native side, where
   BootReceiver also reads it, and the UI re-reads state AFTER the write
   instead of trusting its own intent.

2. The notification stops promising what does not exist. "tap to record"
   becomes "autostart fired - collection begins when you open the app".
   Companion has no collector: collection lives in BydNativePlugin inside
   the Flutter engine inside the activity, and a tap merely opens the app.
   The receiver log of 28.07 showed five wakeups in a day, so the old text
   would have hung in the shade almost permanently.

3. A false rationale in ApkFileProvider is removed. In +172 it claimed we
   could not check whether androidx.core is on the compile classpath. Not
   true: share_plus, already in pubspec, declares
   ShareFileProvider : androidx.core.content.FileProvider, which takes a
   minute to verify. A guess had been presented as a fact, exactly like
   the "boot path is a wall" note that stood from +155 for six weeks. The
   real reason to keep our own provider is different and sufficient: the
   stock one wants res/xml path descriptors and serves directories, and we
   need exactly one file.

4. The dead public marker path is no longer retried on every line. The
   write is synchronous and called from the main thread - from onReceive
   (a 10 s budget) and from the heartbeat. The field on 28.07 showed
   /sdcard/Download is dead on this firmware, and we were reaching for it
   on every line, meaning a doomed external-storage call on every head-unit
   wakeup at the busiest moment of boot. The first attempt per process
   stays: the permission could have come back, and the only way to learn
   that is to try.

Gates: 7/7 - OK - 22/0/0 - 485 PASS / 1 WARN (G3) / 0 FAIL,
dart_balance 74/74. New era BJ (6 gates), 33 mutations, every gate fails
when its own subject is reverted.

On the gates themselves, from BJ5: a check for the ABSENCE of a phrase
forbids it everywhere, including in the correction that fixes it. The
first revision failed exactly that way - the corrected comment quoted the
false claim verbatim, and a gate cannot tell a quotation from a claim. It
is now a pair: a short negative marker plus a positive requirement for the
fact itself.
"""

FULL_MESSAGES['cdff2932'] = """\
v0.1.73+172 - the installation path

There is no way to update on the head unit. The stock file manager will
not launch an APK, there is no ADB, and SilentInstaller answers "already
installed" for an existing package and counts that as SUCCESS - an app
that tried and failed does not record success, so installation is never
even attempted. On a phone the same APK with the same signature and the
same versionCode installs over the top without a question, so the cause is
not in the package and picking locks on the installer is pointless.

The cost is not convenience. While updating means uninstalling, EVERY
patch wipes prefs and Drift. The cloud returns trips, snapshots, reveals
and trip_series, but does NOT return samples/hal_samples or partially
collected atlas bands.

Two parts in one build, on purpose. The probe (read-only) answers whether
this firmware has a system installer at all: if it was cut out, no button
will help, and we need to know that before building downloads from GitHub
Releases. The attempt answers whether it actually works. A probe without
an attempt explains a refusal but cannot prove success; an attempt without
a probe cannot say why it failed. The installation cycle everything rests
on costs a full data wipe, so it has to close the question completely.

New:
  ApkInstall - probe and attempt. SAF file selection (needs no storage
    permission, which is lost after every reinstall here, and it sees the
    USB stick), copy to cache, hand-off to the installer via TWO actions in
    a row: ACTION_VIEW and the deprecated ACTION_INSTALL_PACKAGE, which on
    some OEM firmware is registered instead of the first. Every step
    reports the exception class name.
  ApkFileProvider - a single-file provider. Ours rather than the androidx
    FileProvider: that one would pull androidx.core onto the compile
    classpath, which cannot be verified locally (Gradle does not run in the
    container), and "almost certainly present" would mean a CI build
    failure.
  install_update.dart - a screen in Settings -> Advanced behind the same
    15-tap lock: probe, permission grant, selection, install, attempt log,
    export into the diag dump.

Manifest: REQUEST_INSTALL_PACKAGES, the provider with a grant, and a
<queries> block for four intents and three installer packages. Without
<queries> the probe on Android 11+ would return empty for a perfectly
alive installer - lying in exactly the direction that would have closed
the subject as hopeless.

Gates: 7/7 - OK - 22/0/0 - 479 PASS / 1 WARN (G3) / 0 FAIL,
dart_balance 74/74. New era BI (8 gates), 26 mutations, every gate fails
when its own subject is reverted.

Separately, on tooling: comment stripping inside the gates broke on the
literal "*/*" - a MIME mask contains the sequence /*, the regex took it
for the start of a comment and ate code up to the next */. Half of
ApkInstall.kt disappeared that way along with a function definition, and
BI3 reported FAIL on correct code. The same trap as +165 through +170,
turned inside out: checks used to read comments as code, and now the
stripper read code as a comment. Added _strip_comments_safe, a parser
that survives literals; era BH moved onto it too, since there should be
one tool.

Gate X4 meanwhile caught a real defect: the screen used the localisation
lookup without subscribing to LocaleService.

No networking here. Downloading from GitHub Releases comes separately, and
only if it turns out the installer is reached at all.
"""

FULL_MESSAGES['3186fc56'] = """\
v0.1.72+171 - the autostart bridge

The +169 experiment is closed, negatively. The first readable marker
(28.07, rescued by the fallback path from +170) shows three born: lines,
all three paired with armed: - the owner opened the app. Zero
resurrected:, zero destroy:: the process is killed hard and the system
schedules no restart. On the same hardware recon came up by itself 7-8 s
after each of four head-unit wakeups, and the only difference is that it
has a receiver and we have had none since +155.

This installs the recon p115 bridge: BootReceiver catches BOOT_COMPLETED /
QUICKBOOT_POWERON / MEDIA_MOUNTED, sets setAlarmClock on itself and brings
up AutostartService from the alarm context, where startForegroundService
is permitted. A direct FGS start from boot context is not attempted - the
mAllowStartForeground wall is there (recon p113).

The receiver raises the service with ACTION_BRIDGE rather than ACTION_ARM.
With ARM the marker would show an armed: line indistinguishable from the
owner opening the app, and the +171 experiment would be as unreadable as
+169 was. The discriminator is the bridged: line.

New:
  AutostartMarker - a log shared by service and receiver. The two-level
    write from +170 and the process tag moved here: there is one file
    (public Downloads is dead, we only read the private copy out of the
    export ZIP), and a shared tag proves bridge and service share a
    process.
  AutostartPrefs - an arming flag that outlives the process. commit(),
    not apply(): the head unit kills processes hard and may not wait for a
    deferred write. Written in arm/disarm, so head unit only - Dart sits
    behind the canUseHal gate.
  BootReceiver - the bridge. Alarm exactness under canScheduleExactAlarms(),
    degradation recorded as exact=no; no branch dies without a marker line.

Changed:
  manifest: the receiver with four actions, MEDIA_MOUNTED with
    scheme=file, RECEIVE_BOOT_COMPLETED / SCHEDULE_EXACT_ALARM /
    USE_EXACT_ALARM; the claim that the boot path is a proven wall,
    standing since +155, is removed.
  AutostartService: a third branch, bridged:; the notification says "came
    up by itself" on both owner-free paths; the duplicated up/el pair in
    the born line is gone, ident() supplies it.
  MainActivity: arm/disarm now persist the flag.

Gates: 7/7 - OK - 22/0/0 - 471 PASS / 1 WARN (G3) / 0 FAIL,
dart_balance 72/72. New era BH (8 gates); AW14, AW16, BF3, BF4, BF5 and
BG1 re-pinned era-aware. Mutation testing: 17 mutations, every gate fails
when its own subject is reverted, plus a check that deleting any of the
three new files yields FAIL rather than crashing the run.

Field acceptance criterion: born: plus bridged: in the marker on a
head-unit wakeup without the owner, preceded by a FIRED /
ALARM_SCHEDULED -> OK pair.
"""

FULL_MESSAGES['41e09ce1'] = """\
v0.1.71+170 - "the marker gets through, the labels stop colliding"

Base: +169.

THE MARKER WAS SILENT AND THE +169 EXPERIMENT WAS UNREADABLE. The database
holds atlas snapshots stamped v0.1.70+169 and the "autostart armed"
notification is up on the head unit, so the build is installed and the
service is alive - yet the marker holds a single line from 24.07, neither
born nor armed. Cause: marker() wrote ONLY to /sdcard/Download and
swallowed any refusal into Log.w, which nobody reads in the field. On this
firmware the storage permission is lost after a reinstall - an open item
since +166, and it was in front of me while I built an experiment on that
channel.

Now two levels, as DiagDumpFile has done on the Dart side for a long time:
public Downloads, private directory on refusal, and the file itself
reports where it landed with a "marker: public Downloads unwritable
(fails=N)" line. The private copy leaves in the export ZIP as
autostart_marker.txt - getApplicationSupportDirectory() on Android is
exactly Context.getFilesDir(), where the Kotlin side writes. It gets out
without ADB and without a file manager.

THE fresh-boot FLAG IS REMOVED, IT LIED. It was computed as
upMs < FRESH_BOOT_MS, encoding the assumption that BOOT_COMPLETED only
arrives at low uptime. The recon receiver log of 28.07 shows FIRED
BOOT_COMPLETED at 12:29 on a system that had been up since the previous
day: uptimeMillis is monotonic KERNEL time, it does not reset when the
framework restarts over a live kernel - and it is the framework that
broadcasts BOOT_COMPLETED. So neither clock can tell a cold boot from a
container restart. Third approach to this flag and the last: +157 measured
elapsedRealtime, +162 moved to uptimeMillis because el lied across sleep,
+170 removes the output entirely. The up/el pair stays - it shows whether
the process survived sleep - but there are no more claims about the nature
of the boot. Three orphaned comments discussing the removed flag are
cleaned out too.

LAYOUT, from the owner's photographs of 28.07.

The "current trip" card: the labels for distance, energy and consumption
sat ON the divider line. That is overflow, not padding. Wide-view budget:
cell 58 dp (value 36 -> 43, gap 2, label 11 -> 13), two rows 117,
Divider(height:16) paints its line in the middle of its band (8 dp below
the row), header 34 - 167 dp in total. The panel sits in an Expanded, and
at a smaller height a Column with mainAxisAlignment.center pushes content
outside the box; the label is last, so it lands exactly on the line, and
in release it happens silently. Invisible on BZ3, where cellFontSize is 22
rather than 36. Fix: FittedBox(scaleDown) per cell. No constant was tuned
- the exact height coming from Expanded is not visible to me, and
scaleDown is correct at any of them.

The atlas cell: the star moved to the right of the mean, with the range
below them. The old order mean -> range -> star did not fit (BZ5 81.7 dp
in a 78 dp cell, BZ3 75.8 in 68), and in the photographs the star is drawn
OUTSIDE the dark rectangle in every cell that has a range, and inside in
the one that does not. Owner's decision. This yields 59.7 and 55.8 dp with
room to spare, and the vertical position of the mean no longer depends on
whether a range is present. FittedBox on the row: with a five-digit mean,
mean plus star would come to ~110 dp against a cellW of 104.

GATES. Era BG, four gates: BG1 two-level marker write and a report of the
chosen path, BG2 the private copy in the export, BG3 the order inside the
atlas cell, BG4 the trip cell scales instead of overflowing. AW16 is
re-pinned - its helper required the presence of the removed flag, and now
at pv >= 170 requires its ABSENCE.

All five were mutation-tested, and it paid off twice. BG3 in its first
revision used .index(): deleting the star did not make it fail, it CRASHED
THE WHOLE RUN with an exception and produced no report at all - replaced
with .find() and a -1 check. And the AW16 helper was reading the flag's
history out of its own comments: the fifth patch in a row with that trap
(BD5 in +165, BE8 in +166, the vacuous test in +167, BF1 in +169), so the
helper now strips comments.

KOTLIN CHECKED SYNTACTICALLY FOR THE FIRST TIME. kotlinc 1.3.31 is
available in the container (it is written in CLAUDE.md; I did not know).
AutostartService.kt parses cleanly - only the documented false positives
about overriding nothing remain, caused by the absence of the Android SDK
on the classpath. A pre-existing trailing comma in NotificationChannel was
removed as well: production Kotlin 2.1 accepts it, but the old kotlinc
complained and made the output hard to read.

Gates: 7/7 - OK - 22/0/0 - 463 PASS / 1 WARN (G3) / 0 FAIL.
dart_balance: 72/72, 0 missing-import. The +169 tree under the new
regression suite: 460 / 1 / 0.
"""

FULL_MESSAGES['51d21d87'] = """\
v0.1.70+169 - "autostart, step 1: a watchdog without BAL"

Base: +168. One behavioural change, deliberately one.

THE MECHANISM IS PROVEN. The recon field heartbeat (27.07): three
rebirths in an evening, monotonic uptimeMillis across all three (the OS
did not reboot), no destroy at all, null intent on all three. STICKY DOES
work on this firmware; the recall of 22.07 was wrong, and the standby
bucket theory is withdrawn with it.

A CORRECTION TO THE ANALYSIS, IN ITS OWN FAVOUR. "No onDestroy, therefore
force-stop" is wrong. A real force-stop puts the app into stopped state,
after which sticky does not work at all - recon's three rebirths simply
could not have happened. onDestroy is also skipped on an ordinary
low-memory process kill, and that is precisely where sticky applies. Read
correctly: LMK kills both apps, the system resurrects recon and does not
resurrect companion.

THE CAUSE. From the second recon answer: recon's LiveMonitorService is
HEADLESS, it never calls startActivity. This service called startActivity
from the background on resurrection, where Android 12 cuts it by
Background-Activity-Launch policy - a service's foreground status does not
by itself grant BAL rights, and the block throws no exception. All this
time the marker was writing `launch=attempted-no-throw` and we read that
as "probably came up". The +157 instrument reported exactly what it could;
the error was in the reading.

WHAT WAS DONE. tryLaunchActivity() is deleted entirely. Resurrection is
now headless: startForeground, marker, START_STICKY, and nothing else.

WHAT WAS DELIBERATELY NOT DONE. The recon side proposes two conditions at
once: remove startActivity AND make the service heavy, actually
collecting. The second is not an edit for companion but a project: recon
is self-sufficient because its storage is on the Kotlin side, whereas here
storage is Drift on the Dart side and a service cannot write to it. Doing
both at once would leave us unable to say which one worked. Only the first
is here, and it gives a binary answer after one day of driving: a
`resurrected:` line with no preceding `armed:` means BAL was the blocker,
service weight is irrelevant and headless survives; no such line means
weight is the issue, and step 2 gives the service its own HAL
subscription (Bz5EngineAdapter takes a plain Context, not an activity, so
the vendored layer is untouched). Nothing to lose: zero resurrections in
the entire log so far.

The theory that Android 12 punishes background BAL by refusing to
resurrect the process is NOT part of the plan: no mechanism of that kind
is known, BAL is cut per call. It does not affect the decision anyway -
startActivity is removed because it does not work, not because it is
punished.

INSTRUMENTATION, three small things toward the same end: `resurrected:
headless flags=$flags` writes raw flags, because START_FLAG_REDELIVERY (1)
and START_FLAG_RETRY (2) would distinguish redelivery from an ordinary
sticky restart; `born: ... build=v0.1.70+169` stamps the build, since the
marker has been appended to since +155 and has outlived a dozen and a half
builds, and without a version a before/after comparison is meaningless;
and the notification changes its text on resurrection, so the result of
the experiment is visible on the car's screen without reading a file in
Downloads.

THE LAWFUL PATH INTO THE UI. The notification now has a contentIntent -
tapping it previously did precisely nothing. Until collection can run
headless, a user tap is the only way to raise the app that BAL permits. It
does not affect the experiment: a PendingIntent is passive until pressed.
FLAG_IMMUTABLE is mandatory from Android 12 and is set under an API 23
check.

GATES. Era BF, five gates: BF1 no background activity launch in any
branch, BF2 the marker is headless and carries flags, BF3 the restart
policy is NOT touched (the experiment's control variable), BF4 the
notification reports resurrection and is tappable, BF5 a marker line is
attributed to a build. AW14 re-pinned: the resurrection test moved from
`if (intent == null)` into `val resurrected`, the invariant unchanged.

Comments are stripped BEFORE checking: the docstring names startActivity a
dozen times, and a raw-text check would mean nothing. This is the fourth
consecutive patch with the same trap - BD5 (+165), BE8 (+166), the vacuous
test (+167), now BF1.

Gates: 7/7 - OK - 22/0/0 - 459 PASS / 1 WARN (G3) / 0 FAIL.
dart_balance: 72/72, 0 missing-import. Six gates mutation-tested. The
+168 tree under the new regression suite: 455 / 1 / 0.

Kotlin was not compiled: the patch-building environment has neither a JDK
nor the Android SDK. Bracket balance and the absence of orphaned
references were checked instead.
"""

FULL_MESSAGES['e00767ad'] = """\
v0.1.69+168 - "hotfix: the tests clean up after themselves"

Base: +167. The app is again not at fault - only the test harness is
fixed. Three version lines change in lib/.

WHAT HAPPENED. The test.yml run never finished: forty minutes without a
verdict. The cause is in the tests, and entirely mine.

SpeedProfileService starts two periodic timers in _attach() - a 1 Hz
virtual tick pump and a 30 s persist - plus a subscription to the HAL
stream. Only dispose() cancels them. The test never called it, so five
services left ten live timers behind, and `flutter test` does not exit the
isolate while timers are pending. The tests passed; the process simply
never returned.

Why it did not show on the first run (+166): there a test failed, and the
runner tore down on the non-zero exit code. A green run exposed the leak.
The first version "worked" precisely because it was broken.

WHAT WAS DONE:
  * svc.dispose() in tearDown, FIRST, before the database is closed. In
    the other order the 1 Hz timer would keep knocking on a closed
    database.
  * DROP TRIGGER IF EXISTS in tearDown: if a test dies between CREATE and
    DROP, the trigger does not leak into the next one.
  * @Timeout(60 s) on the file and --timeout 90s on flutter test. A hang
    has to fail fast and name the culprit rather than eat the whole job
    without a hint.
  * timeout-minutes 15 -> 10.

GATE. BE8 gained a >= 168 branch: the test must contain svc.dispose(),
and BEFORE db.close(); it must carry @Timeout; and the workflow must pass
--timeout. All three requirements mutation-tested.

Gates: 7/7 - OK - 22/0/0 - 454 PASS / 1 WARN (G3) / 0 FAIL.
dart_balance: 72/72, 0 missing-import. The +167 tree under the new
regression suite: 454 / 1 / 0.

The Dart tests were still not run by me: the patch-building environment
has no Flutter, and the Dart archive is outside the network allowlist.
"""

FULL_MESSAGES['510a757c'] = """\
v0.1.68+167 - "hotfix: tests that test something"

Base: +166 "honest writes". The app behaves correctly - two of the five
tests were wrong. CI showed that, which is exactly what it was set up for.

WHAT THE FIRST RUN SHOWED.

The test "a chunk is written at 120 s" failed: expected below 120, got
127. Not a code problem. `atlasLiveBands().timeS` returns `sessionTimeS`,
that is `frozenTimeS + timeS`, and it does so DELIBERATELY - the +164
decision, so the number on the card does not jump backwards after the
accumulator is reset. 127 = 120 frozen plus 7 live. The +166 machinery
worked exactly as designed; the test's assertion was wrong.

WORSE, AND THIS IS THE POINT OF THE PATCH: for the same reason the test
"a failed insert does not eat the accumulation" was VACUOUS. It checked
`>= 120`, and on a lost accumulation the value would be exactly 120
(frozen=120, live=0). The test could not fail under any breakage - it
confirmed its own existence rather than the A1 identity. It "passed" on
the very first run, and that was a false green.

The class of error is not new: in +165 I twice caught a gate reading its
own comment (BD5, then BE8 in +166). This is the same thing a third time,
now in Dart tests - an assertion resting on a quantity that is identical
under correct and broken behaviour.

WHAT WAS DONE.

Test 3 is rewritten onto a discriminator that cannot be vacuous: after the
first chunk, drive another 120 s and require a SECOND snapshot. A second
chunk is only possible if the accumulator was reset, because crossing the
threshold requires beforeS < 120, and without a reset cell.timeS stays
above the threshold forever and the condition never holds again.

Test 5 is rewritten as failure WITH RECOVERY. Instead of closing the
database, an SQLite `BEFORE INSERT ... RAISE(ABORT)` trigger, which can be
removed. Driving under the trigger: zero snapshots, the failure counter
rises, the cell sits in the retry queue. Remove the trigger and drive on:
exactly one row, steadySeconds >= 120, the queue empty. That is the A1
check on the merits - the measurement was not lost, it waited and was
written. The table name comes from Drift via `actualTableName`, so a typo
cannot masquerade as a defect.

Two public getters are added, `atlasInsertFailuresTotal` and
`atlasFreezeRetryPending`. Without them write state is observable only
from the diag dump, and the test was forced to lean on session sums. The
pair is useful to the app too: a silent write failure becomes visible.

GATES. BE8 strengthened (era-aware, >= 167 branch): the tests must contain
both discriminators and must NOT check through
atlasLiveBands().firstWhere. BE10 added for the two getters. Both new
checks passed mutation.

Gates: 7/7 - OK - 22/0/0 - 454 PASS / 1 WARN (G3) / 0 FAIL.
dart_balance: 72/72, 0 missing-import. The +166 tree under the new
regression suite: 453 PASS / 1 WARN / 0 FAIL.

The Dart tests were still not run by me - the patch-building environment
has neither Flutter nor Dart, and the Dart archive is outside the network
allowlist. The first test.yml run will be their verification.
"""

FULL_MESSAGES['9ed6d90a'] = """\
v0.1.67+166 - "honest writes"

Base: +165. The patch does not move the screen by a pixel - everything is
inside the engine, the counters and the harness.

WHAT WAS BROKEN (A1). In _freezeChunk the cell accumulator was zeroed
SYNCHRONOUSLY, before the insert; the insert went out unawaited with a
`catch (e) { debugPrint(...) }`; and then _persist() committed the zeroed
state into prefs. A full disk, a locked database, a failed migration - and
120 seconds of measurement vanished for good, without a trace. On screen
everything still looked right, because the card paints frozen plus live and
frozen already included that chunk. The same class of silent substitution
that +164 was built to stop, on the write side instead of the restore side.

The old docstring reasoned about a "kill in between" and was right - but it
described KILLING THE PROCESS, not a FAILED INSERT. There was a chasm
between the two.

Now the cell is untouched until the insert is confirmed. On failure the
accumulation stays put, the key goes into _freezeRetry, and _atlasTick
retries on the next qualified tick. The retry is mandatory: crossing the
threshold happens exactly once per accumulation round, so without it a
single failure would mean never - on the next tick beforeS is also >= 120.

The reset became a SUBTRACTION rather than a zeroing: it moved past the
await, and ticks run at 1 Hz and keep pouring into the same cell during the
insert. `= 0` would throw away whatever accumulated. The amounts taken
before the await are subtracted, temperature sums included. One cell, one
insert in flight (_freezeInFlight), otherwise a retry and an ordinary
crossing could write one chunk twice.

THE GHOST CARD (A2). The collection ceiling of 140 was applied only on
write. A cell for the 160 band was happily created in putIfAbsent,
accumulated, and returned from atlasLiveBands() - so a full "band 160,
maturing" card appeared on screen, its bar ran all the way to 120 s, and
only then did _freezeChunk notice the ceiling, delete the cell and exit
silently. A driver on the motorway watched a measurement fill up completely
and then disappear, having yielded nothing.

The ceiling is a grid boundary, not a write-time rejection threshold. It
moved to where the cell comes into existence. Plus a filter in
_AtlasLedger.fromJson: an upgrade from <= +165 could carry a live
above-ceiling cell in prefs, where it sat legitimately. The check in
_freezeChunk stays as insurance against a third creation path.

THE 140 CEILING IS CONFIRMED PERMANENT (owner, 27.07). The discussed
unlock to 150-180 once the whole grid is closed is rejected: the condition
is unreachable - the grid is 11 bands x 12 temperature windows = 132 cells,
and the lower windows on the upper bands do not meet physically, because
the pack heats under load faster than 120 s accumulate. A gate that never
opens is worse than an honest ceiling.

COUNTERS (B1). Neither of the two fixed failures left a trace anywhere but
debugPrint, which nobody reads in the field. Added to the diag dump:
insert_failed_this_process, insert_failed_total (survives the process - a
lost measurement is something you find out about later, and on the head
unit the process dies with the ignition), above_ceiling_at_create,
above_ceiling_at_restore, freeze_retry_pending. In TickDiag: z100AbortDip
and z100AbortTimeout - an aborted acceleration attempt previously left no
trace, so "how many runs did traffic eat" was unanswerable in principle.

DOCUMENTATION THAT LIED (C). The comment above kAtlasBandMaxCollectKmh
claimed the chart "keeps the 40-180 range". Untrue ever since the chart
moved onto the atlas grid: _BandBarCard builds bands up to
kAtlasBandMaxKmh, that is to 140, and takes values from grid cells. Gate
BC5 pins 11 bands. The comment outlived a code change and had time to
mislead the architecture review - rewritten completely.

The speed calibration method is now recorded: a real 100 km/h is 102 on the
BZ5 speedometer (measured by GPS), hence 100/102 ~ 0.980. The old wording
"~2% high" named the figure but not the method.

The 0-100 convention is named: the zero point is 2 km/h on the dash, not
zero, so the metric is really "2 to a real 100" and the reported time is
systematically a couple of tenths short. It cannot be done otherwise -
speed is integral and arrives on change, and the app is not told the moment
of departure from zero. Not a defect, but it has to be stated.

HARNESS (D). Three seams, without which the engine could not be raised in
a test: HalTelemetrySource, an interface of the nine members the engine
actually touches, instead of a singleton nailed to the platform channel
(behaviour unchanged, AA2 untouched); AppDatabase.forTesting(QueryExecutor)
for an in-memory database; and clock injection at the two tick entry points
(_onEvent, _onVirtualTick), after which time flows as a parameter, so two
substitutions are enough to replay 120 seconds of accumulation in
milliseconds. The other 19 DateTime.now() call sites are deliberately
untouched.

test/speed_profile_engine_test.dart - five tests: a cell below the ceiling
lives, above it is not created, a legacy cell is dropped on restore, a
chunk is written at 120 s with the remainder carried over, and a failed
insert does not eat the accumulation (the database is closed, the most
honest way to get an exception without a mock).

.github/workflows/test.yml - a separate workflow, independent of build.yml,
so a red test does not block the APK build. lint.yml stays off; its noise
would drown the signal.

GATES. BB13 and BC7a re-pinned - both held the old reset shape (zeroing
rather than subtraction), both era-aware. New era BE, nine gates: BE1 reset
only after a confirmed insert, BE2 retry and event only on a real crossing,
BE3 one insert in flight, BE4 ceiling at the source, BE5 filter on restore,
BE6 counters reach the dump, BE7 the three seams, BE8 tests and CI, BE9 the
stale claim about the chart is gone.

Each of the eleven was mutation-tested: reverting its subject in a copy of
the tree must fail that gate specifically. On its first run BE8 read
`flutter test` out of its own comment in the workflow - the same trap BD5
fell into in +165 - so the check was narrowed to non-comment lines.

Gates: 7/7 - OK - 22/0/0 - 453 PASS / 1 WARN (G3) / 0 FAIL.
dart_balance: 72/72, 0 missing-import. A virgin +165 under the new
regression suite: 445 PASS / 1 WARN / 0 FAIL.

NOT VERIFIED: the Dart tests were not executed - the patch-building
environment has neither Flutter nor Dart, and the Dart archive is outside
the network allowlist. The first test.yml run will be their verification;
it does not block build.yml.
"""

FULL_MESSAGES['29c4f9f5'] = """\
v0.1.66+165 - "measurements: text and scale"

Base: +164 "durability and two columns".

PART 1 - TEXT. 42 keys across both maps. Dash connectives, dot separators,
arrows and the "approximately" sign are replaced by words and ordinary
punctuation. English is corrected on equal terms with Russian: the head
unit's system locale is Chinese, "system" resolves to "en" (the contract
sits in the strings.dart header), so a fresh head unit shows English - and
the two lines that were truncated with an ellipsis at 560 dp
(measure.sync_sub, atlas.counts_view) were broken there identically.

Three separators turned out to be hardcoded in Dart, bypassing the
dictionary: the status chip tail, the last 0-100 run line, and the atlas
entry line. The first two became commas, the third a colon.

The word "view" is dropped from atlas.counts_view. It names a mode of the
atlas SCREEN, not a counter, and atlas.view_only exists for that.

PART 2 - SCALE. The screen lived on font sizes 20/22/24/25/26/27/58/64 at
radius 24 and padding 26/36 - roughly twice the rest of the app. Cause: the
1.3 mockups were drawn on a 2175 canvas without checking the existing
scale, with a 150 px rail against a real 80 dp. Everything is brought onto
the ladder 11/12/13/16/18/24/32/34, radius 12, padding 14.

Band card height 159 -> 82 dp; with a 92 dp slot, eight cards fit into a
736 dp column instead of three. In the dump of 27.07 the session held seven
bands, so scrolling stops being mandatory.

Two layout breaks fixed: the collapsed 0-100 card held its title and
readiness line in one Row behind a Spacer, and Spacer(flex 1) plus
Flexible(flex 1) split the free space in half, so the phrase got half the
remainder and folded into a four-line column at the right edge - the
caption moved onto a second line. And the band card subtitle ran to three
lines; after the in_atlas edit and font size 12 it fits on one.

The InkWell ripple radius of the atlas entry card lives on a separate line
from the body radius - brought to 12 along with it, otherwise the touch
would round on its own corner and spill outside the card. Gate BD8 keeps
them equal.

The trip totals card (24/25/20, radius 24) is brought onto the ladder as
well: the canon table does not name it explicitly, but the diagnosis
counted its font sizes. The vertical padding of the OK button is
deliberately left at 16 dp - the canon requires a touch target of at least
48 dp.

RIGHT COLUMN ORDER: atlas -> 0-100 -> sync (owner's decision of 27.07,
superseding the order from 26.07). Of the three, only the sync card comes
and goes with parking; in the middle it pushed the 0-100 block down under
the driver at the moment of parking, and last it moves nothing.

CLOUD, TWO ITEMS.

1. fetchDeviceMe now reads vehicle {id, display_name}. The field has been
   served since S4 and the client never read it - hence "(unknown
   vehicle)" and an empty _vehicleId on the pairing path. Both values are
   persisted; the id is accepted as string or number (the contract fixes
   the field, not the type).

2. The legacy v1 path is removed from startRestore - 121 lines. It existed
   for one stated reason, that /v2/sync/pull answers 400 when the client
   does not know the vehicle. The bridge side closed that on 27.07: the
   server never answers so, the vehicle is derived from the device token.
   So the path could now only do harm - it restores trips and snapshots but
   knows neither the atlas nor trip_series, meaning it would silently
   substitute a truncated restore for a full one, exactly the failure +164
   fixed. A null on the FIRST page is now an explicit restore error instead
   of silence.

   The 400 code is KEPT in the v2Probe triple (owner's decision, 27.07):
   the second consumer is the incremental pull in syncOnce, which swallows
   the exception silently, and narrowing it there is an edit outside the
   frozen scope. The false rationale in the doc is replaced with an honest
   one, marked with when to revisit.

GATES. Re-pinned AF1 (the legacy fallback was mandatory, now forbidden),
BC2 (column order), BC6a (chart literals; the check is narrowed to the
chart class slice - the old one searched the whole file and would have
matched the ghost-cell gap). All three era-aware: a virgin +164 passes
under the old rules.

New era BD, eight gates: BD1 no machine punctuation in either map, BD2
load-bearing wordings, BD3 separators hardcoded in Dart, BD4 the font and
radius ladder, BD5 the section 2.4 break, BD6 the slot arithmetic
82+10=92, BD7 vehicle parsing and persistence, BD8 ripple and body radius
equal.

Each of the eleven was mutation-tested. On its first run BD5 read its own
comment, where Spacer and Flexible are named - the check was narrowed to
code lines.

Gates: 7/7 - OK - 22/0/0 - 444 PASS / 1 WARN (G3) / 0 FAIL.
dart_balance: 72/72, 0 missing-import. The mirror mirror_plus164.py reads
field dumps rather than lib/ - the engine (speed_profile_service,
atlas_projection, database) is untouched by this patch.
"""

FULL_MESSAGES['baff8ea3'] = """\
v0.1.65+164 - "durability and two columns"

Block B - restore from the cloud.
  B0  ClientException is caught in _getJson and _postIngest. This was the
      root cause of the restore failures of 24-26.07: package:http wraps a
      socket abort while reading the body into ClientException, and it was
      caught nowhere in lib/. The line from the head-unit screen at 20:39
      was ClientException: Software caused connection abort,
      uri=.../v2/sync/pull?since=16908&limit=500
  B1  restore applies page by page, the same shape as _syncPull. A failure
      costs one page rather than ~2500 buffered rows.
  B2  the pull cursor is persisted AFTER a page is applied, so the next
      attempt continues instead of dying in the same place.
  B3  restore limit 200 instead of 500 - a shorter body on weak Wi-Fi.
  B4  series/atlas/reveals/pages counters in CloudRestoreProgress.
  B5  the restore summary is persisted (cloud_sync_last_restore_summary).
      The plan's premise was wrong: AppDiagLog does replace the global
      debugPrint and the lines are already in the ring - but the ring lives
      for one process.
  B6  restoreError / lastRestoreAt / the summary in the diag dump.
  B7  a restore offer on an empty database or after a failure.

Block A - measurement durability, a fixed 120 s window.
  The snapshot is written at the kBandMinSeconds crossing and the
  accumulator is zeroed; the remainder carries over (canon section 8). The
  row stays immutable - neither the contract nor the server changes (agreed
  with the bridge side, 26.07). Canon section 6.13 is preserved through
  provisional rows: AtlasGridData excludes rows of the active session from
  cells, counters, the YEAR line and the export; after rotation they become
  cells with not a single record. The cards, section 6.13 and the "N more
  seconds" line read session sums (frozen plus remainder), so nothing rolls
  backwards (invariant I1).

Blocks C/D/E - two columns on BZ5, the chart from the atlas, first entry.
  BZ5 right column: atlas -> sync -> 0-100, one order in every state. BZ3
  gets no columns; its feed follows canon section 7.4: band cards -> 0-100
  -> atlas -> sync -> chart. The chart reads the atlas grid, always 11
  bands, highlighting behind a > 0.5 guard, outer width not a literal
  (80 dp rail plus divider). From the UX review: the sync card exists only
  when the cloud is actually connected - its caption asserts a fact.

Gates: era BC, 14 checks. 436 PASS / 1 WARN G3 / 0 FAIL.
Mirror tools/mirror_plus164.py - ALL PASS on the field dumps of 26.07.
Scan tools/dart_balance.py - 72/72 balance, 0 missing-import.
"""

FULL_MESSAGES['8e348740'] = """\
v0.1.64+163: measurements to contract, pass A

The Measurements screen is rebuilt to canon 1.2 sections 7.1/7.4 (mockups
2a/2d and 3a/3d): the ledger is the source of the band cards, the
Start/Stop/Reset buttons and the A/B comparison archive are removed
(recording is always on), the diag dump moved to Settings -> Advanced,
status chip per section 6.2, empty states 2d/3d, 0-100 collapses when runs
is empty, and the intention line "hold {v} km/h for another {t}" (decision
of 26.07, item 6).

Service: _active is always true (the prefs key is reserved, untouched);
session rotation happens AT REST under a single predicate (a 30 min gap AND
a non-empty session) - a standing tick, insurance while moving, recovery in
init; freezing happens ONLY on rotation or recovery (the window-switch
freeze is removed); displayWindow latches at rest (invariant I1
structurally); the card read API is atlasLiveBands / atlasLiveCellKwh100 /
atlasCellTimeS.

Atlas: median becomes a steady_seconds-weighted mean (one place,
atlas_projection); nav.cells becomes "Battery". Range has a single funnel,
atlasRangeKm (band_card.dart).

Gates: era BB1-BB13; era-aware AW8/AW9/AW11/AW13.
Verification: mirror_plus163.py 24/24 on the field dumps of 25.07 and
26.07.
"""

FULL_MESSAGES['1442ef48'] = """\
v0.1.63+162 "atlas" - field fixes, human language, intention

The drive of 25.07 produced three verdicts; all three are closed.

1. THE IN-MOTION BLOCK IS REMOVED. The full-screen "available when parked"
   placeholder on BZ3, the centred label on BZ5 and the dimming of the
   entry card are gone, two lines deleted. The map carries no live
   information and nobody will look at it while driving - but a placeholder
   instead of the map was irritating. Invariant I1 is not violated: nothing
   still APPEARS while moving, and the totals plate and the Measurements
   badge keep isParked as a conjunct.

2. LANGUAGE. Jargon is replaced with plain words throughout: pack becomes
   battery, the fork becomes from/mean/to, the frontier becomes neighbouring
   cells, a snapshot becomes a measurement, independent sessions become
   drives, and "the atlas closes not by grid but by year" becomes "the full
   picture builds up over a year". The word band stays in Measurements by
   the owner's decision, while the atlas speaks in km/h. Real defects
   found: an abbreviated month name leaked into prose in three places (a
   full month set was added), the "{month} started" string was rewritten,
   and "1 measurement" got proper pluralisation.

3. THE COUNTER ON THE ENTRY CARD LIED. Head-unit tabs live in an
   IndexedStack, so the entry card's initState ran once per process - "1
   cell" all day with three in the database. An atlas revision counter is
   introduced: three writes (freeze, reveal, OK) move it, and the three
   caching screens re-read.

Then what was planned for +162:

  * The 140 cut-off in the engine: above the ceiling there is neither a
    snapshot nor an event, and the cell leaves the ledger instead of
    accumulating in it forever. The number is written in exactly two files
    (engine and projection).
  * A matured but not frozen cell is visible in the grid as a dashed
    outline with its number, plus an explanatory line - so the discrepancy
    "band 40 matured but is not in the atlas" no longer looks like a bug.
    The overlay comes from the live ledger and is NOT part of the
    projection: not in the counters, not in the stars, not in the export.
  * Intention (section 6.10, mockup 5c): a card below the totals, "Take" /
    "Another cell", ghost selection directly in the grid (selection mode:
    cells stay quiet, only dashed ones are tappable), and silent removal -
    on completion, on change, and after 14 days. The candidate is sought in
    the ACTIVE temperature window, which fixes a hint that used to suggest
    a cell unreachable today.
  * AutostartService.kt: fresh-boot is computed from uptimeMillis (which
    stands still in deep sleep), and both numbers are written to the marker
    log.

Gates: check_repo 7/7 - const_l10n OK - hal_sync 22/0/0 - regress 409 PASS
/ 1 WARN (G3, pre-existing) / 0 FAIL. Era BA (7 gates); AW16, AZ2 and AZ10
made era-aware. Mirrors: mirror_plus161 49/0, mirror_plus162 25/0 on the
14:20 diag dump and the 14:21 export.
"""

FULL_MESSAGES['a35186f3'] = """\
v0.1.62+161 "atlas" patch 3 - the presentation layer

The atlas grid on three form factors, the YEAR line, cell detail, a fifth
phone tab, a 14 dp badge, a sticky totals plate, a parking chip, and a
1080x1350 export image with a QR code. The reward engine and the prefs
ledger are NOT touched - they go into +162.

Owner's decisions of 25.07 (overriding the 1.1 contract draft):
  * the coverage mark stays a STAR with bronze/silver/gold shades - the
    chevron rosette is dropped, coverage_mark.dart is not created;
  * the word "atlas" stays in every string, no alternative name;
  * snapshots for bands above 140 km/h are invisible to the grid, the
    header counters, the year line and the export - the cut-off sits in ONE
    reading query, while the engine waits for its own cut-off in +162;
  * "best cell" means the maximum of total steady time, not the minimum
    median: with signed consumption a regenerative descent could steal the
    crown;
  * sharing is available off the head unit only, through a visible preview;
  * the range is not rendered when there is a single snapshot.

Created:
  lib/theme/atlas_tokens.dart         section 2 tokens plus MeasureBadge
  lib/data/atlas_projection.dart      snapshot-to-grid projection
  lib/widgets/atlas_grid.dart         grid, legend, YEAR line, plurals
  lib/widgets/atlas_export.dart       1080x1350 image, preview, sharing
  lib/screens/atlas.dart              atlas screen (phone and BZ3)
  lib/screens/atlas_cell_detail.dart  cell detail (phone)
  lib/screens/wide/atlas_wide.dart    atlas screen for BZ5

Changed:
  charging_banner.dart    sticky plate beside the charging one
  home.dart               fifth tab plus a 14 dp badge on both scaffolds
  head_unit_scaffold.dart 14 dp badge; the isParked dot is off "Vehicle"
  dashboard_wide.dart     parking chip in the header (compensating the dot)
  speed_profile.dart      an additive atlas entry card (otherwise the
                          head-unit screens are unreachable); the totals
                          card and measure.card_* are NOT touched
  database.dart           getAtlasSnapshotsForGrid - one query, with ceiling
  strings.dart            46 atlas.* keys plus 16 export.*, both maps
  pubspec.yaml            qr_flutter ^4.1.0 plus the version
  regress_plus35.py       era AZ (11 gates); U1 and AX5 made era-aware

Gates on this tree: check_repo 7/7 - const_l10n OK - hal_sync 22/0/0 -
regress 402 PASS / 1 WARN (G3, pre-existing) / 0 FAIL.
"""

FULL_MESSAGES['676a9c32'] = """\
v0.1.61+160 - atlas, patch 2: totals card, stars, reveal generation

- reveal generation at the maturing crossing (before < 120 <= after), a
  serialised chain, insertAtlasReveal the single producer (AY1)
- band_matured (first ever, absorbs cell_new), cell_new (a null window is
  its own cell), star_up 5/15 (a port of the contract dedup S10a, with a
  live correction for the current session via a union frame and a
  level-existence guard)
- ledger: t0 per cell (micro-loot gained = timeS - t0), sessionDistKm,
  lastOkMs/lastGainMs (the sum of gained since the last OK under one
  timestamp)
- a totals card at rest (P plus speed 0 for at least 5 s, on the
  Measurements screen): trip line -> events -> micro-loot -> anticipation
  (>= 90 s) -> OK (write-once reveal of everything, syncedAt set to null
  for re-push, lastOkMs latched)
- live Measurements badges on both scaffolds: isParked && unrevealed > 0
  (it does not exist while moving, by construction - invariant I1)
- l10n: 12 measure.card_* keys in both maps; DAO: 6 read/reveal methods
- regress: AX6 re-era'd (generation must exist from +160 on) plus part AY
  (AY1, AY3-AY8); mirror mirror_plus160.py (49 checks, the port matches the
  S10a reference bit for bit, plus 300 fuzz vectors)
"""

FULL_MESSAGES['a3fe9233'] = """\
v0.1.59+158: atlas patch 1 - snapshot layer, temperature windows, +-2, navigation B

Spec: SPEC_plus158_atlas_patch1.md; the API contract is frozen on both
sides; spec v2 recorded.

- kBandHalfWidthKmh 3 -> 2 (dwell physics: the effective acceleration
  threshold is 1.33 km/h/s; the dwell backstop screw is NOT touched - one
  screw per check)
- Drift v16 -> v17: atlas_snapshots (immutable) plus atlas_reveals
  (write-once revealed_at), an idempotent migration, a full DAO
- SpeedProfileService: an always-on atlas ledger on the head unit (armed by
  the probe listener, R5), a band x temperature-window matrix (5 degrees,
  1 degree hysteresis, 5 min temperature stickiness - R1), insert-first
  freezing (R2), session rotation on a 30 min gap, retroactive crash
  recovery, a dirty gate on persistence (R6), a diag dump without a manual
  session plus an atlas section
- CloudSync: push /v1/data/ingest/atlas_* (batches of 200, tolerant),
  pull/restore passes 4 and 5, write-once merge on the client, counters in
  app_diag
- Navigation B: Measurements third on the BZ5 rail and the BZ3 panel
  (Icons.speed, a reveal badge skeleton), History reduced to 2 tabs, the
  phone untouched (item 3), the recording dot not carried onto navigation
- l10n nav.measure EN and RU; gate era AX1-AX7; era-aware: D1 (v17), U1
  (9), U3/V9 (5), AM1, AW1 (Drift permitted), AW7/AW10 (navigation B)

There is NO reveal generation (promise 1, gate AX6) - the queue stays empty
until patch 2.
"""

FULL_MESSAGES['0e806bba'] = """\
v0.1.56+155: corridor dwell, signed band energy, autolauncher

PART 1 - qualification redesigned from the 21.07 dumps (4 slices, +154).
The prediction about V/I failed (ps=1/2861) - power frames do arrive. The
real culprits: (a) the slope estimator still ate 65% of ticks (1881/2861),
which is physically implausible and points to systematic overestimation on
a 2.7 Hz quantised stream; (b) a physics skew among the ticks that passed -
the rule "do not write when P <= 0" recorded the consumption of the impulse
phase only, giving 32.4 on the 40 band and consumption FALLING with speed,
that is inverted physics.

- Corridor gate: a tick is recorded after kBandDwellS = 3.0 s of continuous
  dash presence inside the band window (+-3). Dwell is a robust measure of
  steadiness: you cannot accelerate at more than 2 km/h/s and stay 3 s
  inside a 6 km/h corridor. Least squares, kSteadyAccelMax and the speed
  buffer are deleted.
- Signed energy: regeneration and coasting inside the corridor subtract, so
  a band answers "what holding this speed costs in total", the same way trip
  averages do. negPower is an informational counter of recorded ticks with
  P <= 0. UI: a band may be negative (minY), and range is shown only when
  consumption > 0.5.
- TickDiag: tick / warm-up / outside / V-I / accepted (with P <= 0 inside).
  The diagnostics live until the control drive.

PART 2 - the autolauncher (variant D, spec from the recon side):
- AutostartService.kt: FGS, return START_STICKY; a null-intent resurrection
  calls startActivity(MainActivity) and writes the marker log at
  /sdcard/Download/bz5_companion_autostart_log.txt (the recon p112/p113
  pattern); an explicit ACTION_STOP returns START_NOT_STICKY, which avoids
  the null-restart trap. A quiet IMPORTANCE_MIN notification.
- Manifest: <service exported=false> plus FOREGROUND_SERVICE.
- MainActivity: MethodChannel bz5/autostart (arm/disarm).
- AutostartArm.attach(hal) in main: armed once per launch, strictly behind
  the canUseHal gate, so a phone never gets the service.
- The open BAL question (Android 12 background activity launch) will be
  answered by the marker log from the field; the boot bridge is not taken
  (unverified, and there have been no reboots).

Gates: AW2/AW3/AW12 versioned onto the +155 era, new AW13 (signed energy)
and AW14 (autolauncher). Mirror mirror_plus155 19/19: M2 the urban pulse
equals net analytics, M13 field jitter 99%, M13d a descent honestly
negative. Gates: 7/7 - OK - 22/0/0 - 375/1(G3)/0.
"""

FULL_MESSAGES['73fd0c3f'] = """\
v0.1.55+154: steadiness gate calibrated from the 21.07 field dumps, 120 s threshold

The diag dumps (2430 and 235 ticks) show that the |a| > 1.5 gate cut 79% of
ticks in both sessions, even on deliberately steady driving. Cause: the real
speed cadence is ~2.5 Hz, not the ~8 Hz on paper, and the edge-to-edge
slope estimate stood on two frames - so honest wandering of +-1 km/h read
as 1.5-2.5 km/h/s. The other gates are healthy (V/I at 1.5% and 0%, P <= 0
at 2%).

1) Slope estimation: least squares over every frame in the buffer, window
   1.3 -> 2.0 s. Jitter averages out and a real acceleration shows its true
   slope.
2) kSteadyAccelMax 1.5 -> 2.5 km/h/s (accelerations live at 5-8, so the
   separation is clean; micro-oscillations inside a band are energetically
   almost closed).
3) kBandMinSeconds 60 -> 120 s (owner's decision: a two-minute floor, a row
   must earn trust before it promises range). The maturing-band caption is
   now composed from the constant.
4) The diagnostic counters are NOT removed - the control drive will compare
   the accepted share before and after (5% -> expected 50-70%), and the
   diagnostics come out in +155.

Gates: AW3/AW8 versioned by era, AW12 (least squares; edge-to-edge
forbidden by a marker). Mirror mirror_plus154 17/17, including M13, the
exact shape of the field failure (2.5 Hz, 40 <-> 41): least squares passes
100% of steady ticks while a 5 km/h/s ramp is still cut.
Gates: 7/7 - OK - 22/0/0 - 373/1(G3)/0.
"""

FULL_MESSAGES['e85a75fe'] = """\
v0.1.54+153: tick-gate diagnostic counters (TEMPORARY), "bands are maturing", diag dump

Field report of 20.07: six to eight minutes of steady 40 km/h and no bands,
while 0-100 was recorded and distance and the temperature passport were
alive. The export ruled out the power sign (peak +200.85, regen -83.6),
signal names and stream cadence (speed ~8 Hz, I ~2.2 Hz, V ~0.8 Hz inside a
6 s window). The guilty gate is indistinguishable without counters.

1) TEMP DIAG: TickDiag inside the session - tick / no delta-v / |a| over /
   outside / V-I / P <= 0 / accepted (the first gate that fired), persisted
   into JSON, shown as a dimmed line at the bottom of the screen.
2) TEMP DIAG: a "diag dump" button - the full session.toJson() (immature
   bands included) plus the active constants, written as a fenced JSON
   section into bz5_companion_diag.md through DiagDumpFile (the proven
   Downloads-to-USB channel, the Native Explorer journal). BOTH BLOCKS TO
   BE DELETED by a later patch once the diagnosis is in.
3) PERMANENT UX "bands are maturing": bands under 60 s are visible, dimmed,
   with a progress bar reading "N of 60 s". The button row moved to a Wrap.

Gates AW2 (markers for the P-gate split) and AW11 (extended with the dump).
Mirror 15/15 (M12: the counters partition the total without loss).
Gates: 7/7 - OK - 22/0/0 - 372/1(G3)/0.
"""

FULL_MESSAGES['57264e05'] = """\
v0.1.29+105: cell-spread sticky fix, dongle-free HAL coulomb SOH

Two changes agreed with the owner.

CHANGE 1 (cell panel, a +103 regression) - trivial.
cell_v_lowest/highest and cell_idx_lowest/highest are added to _stickyNames
in hal_telemetry_service.dart. These signals (BYDAutoEnergyDevice, DOUBLE,
~48 Hz, dongle-free) passed the range guard and were written into _latest,
but without membership in _stickyNames they were NOT copied into _lastGood,
so useForCellSpread read the held value in halOnly, found null, and the
dashboard_wide battery block fell through to the OBD2 branch (an empty
M1-M10 and a permanent "extremes: loading"). Now the held value is filled,
so the +103 fork shows the pack temperature plate plus min/max V. The
signal is physically present (confirmed on the recon side) - it simply was
not being held. The freshness windows and range guard for these names were
already in place.

CHANGE 2 (dongle-free Ah SOH, variant A) - substantial.
Root cause: the UDS SOH integral in connection.dart only turns while
isCharging, and isCharging reads 0x0B00 over UDS, which is dead in halOnly
without a dongle. Switching the current source alone is not enough - the
charge detection itself is blocked. The solution is a separate charge state
machine entirely inside HalTelemetryService (variant A), independent of the
trip machine:
  - _updateHalCharge() is called from _onEvent next to _updateHalTrip (not
    inside it, not behind the trip gate), so it ticks even with no trip in
    progress - charging happens AFTER the trip closes, at rest.
  - charge detection from HAL: stationary (speed <= 1) AND pack_current <
    -10 A, with a 20 s debounce (the same discriminator as +101).
    Regeneration is excluded by speed.
  - the session anchor (start SOC plus start integral) is taken on the FIRST
    charge frame, before the debounce confirms, so the first 20 s of
    charging enter both the SOC delta and the current integral (otherwise
    SOH is understated). _halSohCharging marks "debounce confirmed"
    (validity); a glitch shorter than 20 s does not trigger finalisation.
  - on charge-to-idle, finalisation: SOC delta >= 20% AND coverage >= 90%
    AND a 50-110% clamp, then full_Ah = accum / SOC_fraction and
    SOH% = full_Ah / 150.0 x 100.
  - connection.dart is NOT touched, so AA2 holds: HAL does not import
    connection, Bz5Model appears only in comments, and the 150 Ah capacity
    is duplicated locally as _halSohPackCapacityAh, the same pattern as
    _halPackCapacityKwh.

DB (schema 11 -> 12, additive): a nullable soh_estimates.source column. UDS
writes id=1/source='uds' (defaults, so the old call is unchanged), HAL
writes id=2/source='hal'. The sources do not overwrite each other.
upsertSohEstimate and getLatestSohEstimate gained optional rowId/source and
stay backward compatible.

UI (3 places: dashboard, dashboard_wide, driver_view_wide): SOH priority is
now hal.halSohAhPct, then svc.sohAhPct, then HAL-BMS (0x02D3), then BMS
(0x0029). The About text is rewritten for two sources. The HAL cache is
hydrated by loadHalSohEstimate() on init, with notifyListeners on
finalisation. _stopStream finalises and resets the HAL session (a mid-charge
stop). regress D1 moves to schema 12.

Gates on a clone: check_repo 7/7 - const_l10n OK - hal_sync 21/0/0 -
regress 267/1 (G3 pre-existing)/0. database.g.dart is in .gitignore, so
drift codegen runs through build_runner on CI.
"""

FULL_MESSAGES['70faf2f9'] = """\
v0.1.29+78: brake-light indicator - a red bar under the speed (regen)

The direct stop-lamp state (LIGHT_CMD_STOP_LIGHT_STATE 0x33100012) is not
available to our uid: recon p086 closed that on three paths
(class_not_found, BYDAUTO_LIGHT_COMMON not granted, binder null). So the
indicator is DERIVED, not lamp state - which is stated in the code and the
comments; in the UI it is simply a red bar.

The rule (HalTelemetryService.brakeRegenActive): motor_torque < -50 Nm AND
pack_current < -60 A (charging; with the discharge-positive convention,
regeneration is negative). Both signals are required: torque alone twitches
on the coast/regen boundary (-48 / -56 Nm), and pairing it with an explicit
charge current removes the false positives while keeping every real episode
(from the recon-side run: -97/-134, -117/-124, -56/-83 Nm/A - both past
their thresholds together).

UI: a red bar (#FF3B30, soft glow) directly under the speed number in
SpeedAndStatusStrip, a shared widget, so it shows on both Driver (6 px) and
Dashboard compact (4 px). The slot has a fixed height (the layout does not
move) and opacity animates over 120 ms. HAL-only by nature: in OBD2-only
mode the signals do not exist, so the bar does not appear - honestly - and a
stale HAL stream extinguishes it rather than freezing it red.

UI plus one derived getter only; decoders and data unchanged.
Version triplet -> 0.1.29+78.

Gates: check_repo 7/7, const_l10n OK, hal_sync 21/0/0,
regress_plus35 259/1 WARN(G3)/0 FAIL.
"""

FULL_MESSAGES['672e7d74'] = """\
v0.1.26+13: hotfix - restore Driver/Analytics tabs and trip detail stat cards on the head unit

Two bugs spotted in the car after installing v0.1.26.60 on the BZ5 head
display:
  1) the Driver and Analytics tabs disappeared from the NavigationRail;
     only Dashboard / Raw Data / History / Settings / Native API remained.
  2) opening a trip from History showed only 4 chart cards (SOC / battery
     temp / pack voltage / HV bus). The speed histogram, the moving/idle
     donut, the odometer range and the summary cards were missing, while
     the phone build opens the same trips with the full set.

Bug 1 - my own regression in v0.1.27. While building the v0.1.27 scaffold I
overwrote lib/screens/wide/head_unit_scaffold.dart with a stub from an
older archive (the v0.1.4 layout: 4 tabs, Dashboard/RawData/History/
Settings). By then the repository already held the v0.1.23 layout with 5
tabs: Driver / Analytics / Raw Data / History / Settings. The old template
had no Driver or Analytics destinations, so when I added Native API as a
fifth destination, Driver and Analytics were erased.

Fix 1: the v0.1.23 five-tab layout is restored with Native API as the
sixth. Driver is speed/gear/SOC/pack V plus 6 trip metrics plus the status
strip (DriverViewWideScreen from driver_view_wide.dart, v0.1.23); Analytics
is cells/modules/pack extremes (DashboardWideScreen). The v0.1.23
parked-badge indicator on the Analytics tab is preserved (a green dot when
the car is in P and Analytics is not active - a hint that idle time is a
good moment to look at pack detail).

Bug 2 - a pre-existing rendering bug in
history_wide.dart::_SelectedTripDetail. That class rendered a Card with the
date plus 4 chart cards and nothing else, while
trip_detail.dart::_buildWideLayout (used when a trip is opened from the
phone) correctly renders 5 further cards with detailed statistics:
TripSummaryCard, DerivedMetricsCard, OdometerRangeCard, MovingIdleDonutCard,
SpeedHistogramCard. Those cards were private in trip_detail.dart, so
history_wide could not import them.

Fix 2 - two linked changes:
  a) trip_detail.dart: the 5 cards are renamed from private to public
     (_MetricRow and _ChartCard stay private as internal helpers). Their
     behaviour and rendering do not change - only visibility.
  b) history_wide.dart: trip_detail.dart is imported, and
     _SelectedTripDetail now uses those 5 public cards plus the same 4
     chart cards as before, laid out in pair() rows as in
     trip_detail.dart::_buildWideLayout: summary | derived metrics /
     odometer range | moving-idle donut / speed histogram full width /
     SOC | battery temp (240 dp charts) / pack voltage | HV bus. The
     head-unit header card with DISTANCE/ENERGY/AVG on one line is kept
     unchanged - it is a head-unit-specific style that complements
     TripSummaryCard.

Untouched: lib/services/connection.dart, elm327_ble.dart, database.dart;
every v0.1.27 scaffold file; AndroidManifest.xml; the phone trip detail
screen; the phone history screen.

Regression testing:
  - bracket balance: trip_detail.dart, head_unit_scaffold.dart,
    history_wide.dart
  - 5 public cards declared in trip_detail.dart
  - 0 stale underscore-prefixed references after the rename
  - history_wide imports trip_detail and uses all 5 cards
  - head_unit_scaffold: 6 NavigationRailDestinations, 6 widgets in _screens
  - every import resolves to a file present in the repository
  - pubspec bumped 0.1.26+12 -> 0.1.26+13
"""

FULL_MESSAGES['0861df91'] = """\
v0.1.26+12: build fix - duplicate batteryCapacityKwh declaration

The release build v0.1.26.60 failed in CI with:
  lib/services/connection.dart:68:23: Error: 'batteryCapacityKwh' is
  already declared in this scope.
  lib/services/connection.dart:22:23: Context: Previous declaration.

Cause: while working on v0.1.26+11 (SOC-derived charging) a second
Bz5Model.batteryCapacityKwh declaration was added, with an extended comment
about the dual pack (65.28 vs 73.984 kWh) and the auto-detect plan, but the
old short declaration on line 22 was not removed. Both were identical
(static const double = 65.28). The Dart compiler rightly refused.

A puzzle: why v0.1.26.59, or other earlier +11 builds, did not catch this is
unclear. Possibly CI simply did not run between v0.1.26+10 and v0.1.26+12,
or it did and the successful v0.1.26+10 was the build artifact. Either way
the fix is to delete the duplicate.

Fix: the declaration on line 68 is kept (the more informative comment, with
both pack variants and the auto-detect TODO). The one on line 22 is
deleted, and the useful information from its comment - the 65.28 kWh
confirmation via the dashboard ETA calculation (13 h 26 m at 2.8 kW from
46% = 35.25 kWh to full, hence a capacity of 65.3 kWh) - is carried into
the surviving comment.

Untouched: all 13 use sites of Bz5Model.batteryCapacityKwh (the Dart
compiler resolves them to the remaining declaration); the other 4 static
consts of Bz5Model (chargeCounterWh, packVoltageScale,
packVoltageInvalidRaw, avgConsumptionWhKm), all verified unique by grep;
every v0.1.27 scaffold change (AndroidManifest, Native API plugin,
head_unit_scaffold).

Regression:
  - grep 'static const double batteryCapacityKwh' -> 1 match (was 2)
  - grep 'Bz5Model.batteryCapacityKwh' -> 13 use sites (unchanged)
  - bracket balance: {} 328/328, () 994/994, [] 96/96
  - class Bz5Model: 5 unique static const declarations
  - pubspec bumped 0.1.26+11 -> 0.1.26+12
"""

FULL_MESSAGES['3e09d581'] = """\
scaffold: native HAL API recon v2 plus a drop-in plugin for head-unit mode

Reconnaissance and scaffolding for running bz5-companion directly through
the BYD car framework on a BZ5/BYD head unit, without an OBD adapter. The
BLE plus ELM path is untouched - this is parallel infrastructure for phase
2.

Decompile sources (androguard 4.1.3): com.byd.diagnosticinfo v1.5.1.0
(1.8 MB), com.byd.byddatachecktool v1.5.0.0 (85 KB), com.byd.CanDataCollect
v12 (870 KB), com.byd.car.server v2.1.0-alpha10 (10.5 MB, 2 dex).

THE KEY DISQUALIFICATION of the old hypothesis: property names in this
system are NOT human-readable strings like 'battery.soc' or 'vehicle.speed'.
They are literal hex feature IDs of the form '0x99002B0A'. Confirmed
through HalFeatureProvider.transformHexString2Long(s) =
Long.parseLong(s.substring(2), 16). There is no semantic name registry in
the system at all - feature ID to semantics has to be mapped empirically by
runtime probing, which is what the Native Explorer UI in the scaffold is
for.

Feature registry: 10016 properties in the server's assets/config_{1,2,3}.bin
(6789 read-only, 2668 write-only, 559 read-write). The protobuf was parsed
via androguard plus protoc and exported to bz5_feature_catalog.csv
(615 KB), with fields property_name, feature ID in decimal and hex,
dataType, access, and interfaceName (a binding to one of 45 BYDAuto*Device
devices).

THE VERIFIED ICarPropertyService WIRE PROTOCOL (from the carserver dex).
Bootstrap goes through BinderProvider, NOT through ServiceManager - there is
no such service at all, only a ContentProvider:
  1. URI content://com.byd.car.server.provider.CarServiceProvider (the path
     is ignored; the provider dispatches on the projection)
  2. projection[0] is the FQCN of the AIDL interface, which acts as the
     service selector. Inside, BinderProvider.query() does
     Class.forName(projection[0]) -> Spi.getService(ctx, cls) -> IBinder.
  3. Cursor.extras.getParcelable('binder') -> BinderParcelable, then
     .getBinder() via reflection -> the final IBinder.

Transaction codes, taken exactly from ICarPropertyService$Stub$Proxy:
TX 1 setProperties (sync, Status), TX 2 getProperty (sync, nullable
Response), TX 3 getProperties (sync, nullable Response), TX 4
getPropertyConfigs (sync, List<CarPropertyConfig>), TX 5
registerValueCallback (oneway), TX 6 unregisterValueCallback (oneway). The
listener (ICarPropertyListener) has TX 1 onEvent(name, Response), oneway.

Parcelable layouts are type-tagged with the Java class name, NOT a numeric
code: Status is writeInt(code) plus writeString(description);
CarPropertyValue is writeString(mPropertyKey), writeString(mPropertyId),
writeString(typeName), writeXXX(value), where typeName is one of
java.lang.Integer/Long/Float/Double/Boolean/String, [B, [I, [F, [J,
android.os.Parcelable; Response is writeParcelable(status),
writeString(typeName), writeXXX(result). This overturns the initial
hypothesis that dataType 1 means Integer, 2 Long, 23 byte[]: dataType in
the protobuf configs is a different quantity, probably a catalogue
category, while the wire type is a Java class name. Calibration through
getPropertyConfigs() is therefore mandatory.

CanDataCollect adds a parallel raw CAN frame channel:
BYDAutoVehicleDataDevice.sendRegisterTable(int version, byte[] table) to
subscribe to a list of CAN IDs, and
AbsBYDAutoBigDataListener.onWholeFrameDataChanged(byte[]) as the callback
with packed frames. Not needed for the dashboard (we use
ICarPropertyService), but it reaches frames that are not exposed as
features.

Also confirmed, HAL methods missing from the first pass:
BYDAutoBodyworkDevice.getAutoType():I (numeric model),
BYDAutoPowerDevice.wakeUpMcu():I, BYDAutoPowerDevice.getMcuStatus():I,
BYDAutoPowerDevice.getPowerCtlStatus(int):I (domain power state),
BYDAutoStatisticDevice.get(int[], Class) (synchronous read). Listener
callback shapes are NOT universal: the statistics one uses a generic
onDataEventChanged(int, BYDAutoEventValue), while Power and BigData have
domain callbacks (onMcuStatusChanged, onWholeFrameDataChanged). The recon
doc previously claimed all Abs*Listener classes have onDataEventChanged -
an over-generalisation, now corrected.

A third channel: the Unix abstract socket diag_socket_channel, a snapshot
DTC database. Commands 'latest_diag_data' / 'all_diag_data'. The response
is 10 columns per row, delimiters '@' for rows and '#' for columns, with
column 8 holding JSON key/value pairs. There is no permission gating at the
AIDL level, but SELinux may cut it on locked builds.

VIN auto-detect for the DataSource resolver:
BYDAutoBodyworkDevice.getRealAutoVIN() (fresh from CAN, ~10-50 ms) and
.getAutoVIN() (cached); a ClassNotFoundException means this is not a head
unit, so fall back to BLE.

Scaffold files, all under bz5_companion_native_scaffold/: BydNativePlugin.kt
(FlutterPlugin plus Method/EventChannel), BydCarPropertyClient.kt (a raw
IBinder.transact() client, TX codes 1-6 verified, parcel layouts verified,
listener stub), BydVinDetector.kt (reflection wrapper, memoised),
BydDiagSocket.kt (LocalSocket plus the '@'/'#' parser), BydPermissions.kt
(a 22-permission catalogue plus a declared/granted reporter),
BydReflection.kt (cached null-safe reflection), MainActivity_example.kt,
AndroidManifest_additions.xml, lib/services/data_source.dart (abstract
VehicleDataSource), lib/services/native_car_channel.dart (a Dart wrapper
over the plugin), lib/services/native_detector.dart (a ChangeNotifier for
isOnHeadUnit), lib/screens/wide/native_explorer_wide.dart (debug UI plus a
feature ID prober), docs/BZ5_NATIVE_API_RECON.md (full recon, v2, 25 KB),
docs/bz5_feature_catalog.csv (10016 features), INTEGRATION.md (a
step-by-step merge guide) and README.md (overview plus a status table).

AIDL strategy: we do NOT use .aidl plus Gradle codegen, because
Response.result and CarPropertyValue.mValue are Objects with runtime
polymorphism through writeString(typeName), and the AIDL stub generator
cannot express that. The bytes are laid out by hand via IBinder.transact(),
mirroring exactly what carserver writes and reads (see recon section 3.1).
If BYD reorders methods in a future firmware .aidl, our client breaks
silently, so there is defensive logging on every branch.

Strictly empirical and not blocking the first build: mapping feature ID to
semantics (SOC, speed, voltage and so on), which is what Native Explorer
exists for - at rest SOC is constant, speed is 0 and voltage is around
350-400 V, so ranges can filter after the first probe export; which
BYDAUTO_*_COMMON / _GET permissions each feature needs, where the manifest
declares a superset (22 permissions, both naming variants) and runtime will
show the surplus in logcat; and the event rate of registerValueCallback,
which needs to be at least 5 Hz for speed and SOC.

Deferred to phase 2: a NativeCarDataSource implementation over the abstract
VehicleDataSource, once feature ID to semantics is calibrated; and the
ConnectionService refactor (a 3519-line god object in
lib/services/connection.dart), left alone for now so as not to break the
BLE flow.

The BLE plus UDS pipeline stays primary, with no changes to
lib/services/connection.dart, lib/data/database.dart or any screen. The
scaffold lives in its own subdirectory, with no side effects on the
existing build.
"""

FULL_MESSAGES['49587e55'] = """\
v0.1.27: scaffold native HAL API, in-app diagnostics, CLAUDE.md

A recon-driven scaffold for working directly with the BYD car framework on
the BZ5 head unit, without an OBD adapter. The BLE plus ELM path is
untouched: ConnectionService (3519 LOC) stays primary, and native mode
switches on in v0.1.28+ once NativeCarDataSource is built over it. The
pubspec version is deliberately NOT bumped: the scaffold changes nothing in
runtime behaviour for a user without a head unit.

NO-ADB CONTEXT: since the recon stage, USB debugging is unavailable on the
BZ5. So all diagnostics are built into the app - a BydLogger ring buffer
(500 records) plus a Native Explorer UI with an in-app log tail (1.5 s
polling), an "Open App Settings" button for granting permissions by hand,
and "Copy diagnostics" for sending a snapshot out. When ADB works again,
ordinary logcat works alongside it.

The APK signature does not change (the same keystore secret in CI), so the
update installs over the top WITHOUT uninstalling and data is preserved.

EXISTING functionality preserved 1:1 - lib/services/connection.dart (3519
LOC), lib/services/elm327_ble.dart, lib/data/database.dart (the Drift
schema), every existing wide screen (dashboard/raw/history/charging/
settings), and every BLE/location/storage permission in the manifest. In
head_unit_scaffold.dart the first four destinations are const-constructed
identically, IndexedStack widget identity is preserved, and the
ConnectionService Provider is untouched, so the ELM flow works as before.

NEW Kotlin (8 files): BydNativePlugin.kt (FlutterPlugin plus 14-method
dispatch plus no-ADB diagnostics: pullLogs, openAppSettings, getDiagnostics,
clearLogs); BydCarPropertyClient.kt (raw IBinder.transact
ICarPropertyService, TX 1-6 verified, parcel layouts verified);
BydVinDetector.kt (a reflection wrapper for BYDAutoBodyworkDevice);
BydDiagSocket.kt (LocalSocket diag_socket_channel); BydPermissions.kt (a
24-permission catalogue plus reporter); BydReflection.kt (cached null-safe
reflection helpers); BydLogger.kt (a 500-entry ring buffer, a Log.* drop-in
that writes to both logcat and the buffer); MainActivity.kt (FlutterActivity
plus BydNativePlugin registration - WARNING: this is the clean version, so
any custom WindowManager flags or themes have to be restored by hand).

NEW Dart (4 files): data_source.dart (abstract VehicleDataSource),
native_car_channel.dart (a Dart wrapper over the plugin plus the
NativeLogEntry class), native_detector.dart (a ChangeNotifier for
isOnHeadUnit), native_explorer_wide.dart (debug UI with in-app log tail, an
environment card, and the Open App Settings and Copy diagnostics buttons).

NEW docs (3 files): BZ5_NATIVE_API_RECON.md (the full recon report, v2,
25 KB), bz5_feature_catalog.csv (10016 features), INTEGRATION.md (a no-ADB
workflow guide). NEW at root: CLAUDE.md, the rules for future Claude
sessions - machine paths, patch format, commit format, the regression
toolbelt, vehicle facts, BYD framework findings, and CI workflow critical
points.

MODIFIED (3): AndroidManifest.xml (+25 BYD permissions plus queries
entries), MainActivity.kt (plugin registration), head_unit_scaffold.dart (a
fifth Native API destination).

THE KEY RECON FINDING: property names are literal hex feature IDs of the
form 0x99002B0A, not human-readable. The catalogue of 10016 features is in
docs/bz5_feature_catalog.csv, and the feature-ID-to-semantics mapping is
done by runtime probing through Native Explorer.

THE VERIFIED ICarPropertyService WIRE PROTOCOL, from the carserver dex:
bootstrap through BinderProvider, where projection[0] is the AIDL FQCN
acting as the selector; TX 1 setProperties, 2 getProperty, 3 getProperties,
4 getPropertyConfigs, 5 registerValueCallback (oneway), 6
unregisterValueCallback (oneway); listener TX 1 onEvent (oneway). Parcelable
layouts are type-tagged by Java class name rather than by number:
java.lang.Integer/Long/Float/Double/Boolean/String, [B, [I, [F, [J. Full
details in docs/BZ5_NATIVE_API_RECON.md section 3.1.

DEFERRED to phase 2 (v0.1.28+): the NativeCarDataSource implementation over
VehicleDataSource, once feature ID to semantics is calibrated; and the
ConnectionService refactor (a 3519-LOC god object), left alone for now so as
not to break the BLE flow.

Regression testing before commit: bracket/paren balance on 8 Kotlin and 5
Dart files (with Kotlin-aware string stripping for template strings);
kotlinc syntax check with 0 unexpected errors; MethodChannel/EventChannel
names matching between Dart and Kotlin; 14 Dart invokeMethod calls against
14 Kotlin when branches; the BydLogger surface used correctly from 5 files;
getDiagnostics map keys, 12 emitted in Kotlin against 12 read in Dart;
AndroidManifest XML well-formed with 35 permissions and a queries block of
3 children; and head_unit_scaffold with the first 4 destinations
const-constructed identically and IndexedStack widget identity preserved.
"""

# ---------------------------------------------------------------------------
# TOKEN_SUBS - short phrases replaced in place, everywhere.
# Longest first: substitution is sequential.
# ---------------------------------------------------------------------------

TOKEN_SUBS = [
    # Collaborator nicknames used across the log. "Friend 2" is the
    # bridge/server-side session, "Friend 3" the head-unit recon session.
    ('Друга 3', 'Friend 3'),
    ('Другом 3', 'Friend 3'),
    ('Друг 3', 'Friend 3'),
    ('Друга 2', 'Friend 2'),
    ('Другом 2', 'Friend 2'),
    ('Друг 2', 'Friend 2'),
    # Cyrillic enumerators used as list markers in a few messages.
    ('(а)-(е)', '(a)-(f)'),
    ('(а)-(ж)', '(a)-(g)'),
]

# ---------------------------------------------------------------------------
# LINE_SUBS - whole lines replaced one for one.
#
# Russian UI labels are glossed in English rather than translated silently:
# the literal in the code is still Russian, and the log must not imply
# otherwise.
# ---------------------------------------------------------------------------

FULL_MESSAGES['688d8ce9'] = """\
v0.1.60+159: CI hotfix - restore the hal_telemetry_service import in history.dart

CI build-232 failed: _TripsTab (history.dart:131) reads
HalTelemetryService.halTripDbId (+111, refreshing the list from the HAL
trip), and +158 removed the import together with the Measurements tab. The
+112 class of error: the Dart gates do not compile. I checked history_wide
for leftover uses and found none in history.dart. The hotfix is one import
line.

Process fix: a systematic missing-import scan across every edited file is
added to the pre-delivery discipline. It found exactly this one.
"""

FULL_MESSAGES['574f30a8'] = """\
v0.1.53+152: Measurements grafted into wide History (the real head-unit entry point)

The +151 field miss (20.07): the build on the head unit was correct
(confirmed by the server logs, app_version 0.1.52+151), but the tab was not
there - the head unit renders lib/screens/wide/history_wide.dart, which uses
a SegmentedButton, while the +151 graft went into the phone's history.dart
with its TabBar.

+152 adds a third Measurements segment to the wide screen: enum
_Tab.measure, the canUseHal gate (the same honesty principle), a
SpeedProfileScreen body, a red recording dot on the segment icon
(_MeasureSegIcon), and a fallback to Trips when the HAL verdict goes away.
The phone graft from +151 stays.

Gate AW10. Service logic is unchanged, so the mirror stays at 14/14.
Gates: 7/7 - OK - 22/0/0 - 371/1(G3)/0.
"""

FULL_MESSAGES['baf3d0cf'] = """\
v0.1.52+151: Measurements - speed profile plus an automatic 0-100

Per SPEC_plus151_speed_profile.md v1.2. A new third History tab (head unit
only, canUseHal), SpeedProfileService on the HAL Test path (rawEvents plus
retain/release), bands at multiples of 10 (+-3, 40-180, a 60 s threshold),
and tick qualification: |a| <= 1.5 km/h/s, P > 0, V/I fresh within 6 s, and
a 2 s dt guard. Distance and energy use the real speed (dash x 0.98), and
the 0-100 finish uses a real 100 with both ends interpolated. Prefs
persistence every 30 s (the +116 pattern), an archive of 24 with eviction on
confirmation, A/B comparison, and the pack temperature passport (U4). Gate
Y4: a versioned allowlist for +151.

Fixes from the architecture review are folded in: item 3, the A/B selection
resets on any archive mutation (a save or an eviction, not only a deletion);
item 7, an idle session auto-stops after 7 days without movement (lastMoveMs
in the persisted state, checked in the 30 s timer and on init-resume), the
stream is released and the session body is kept.

Gates: 7/7 - OK - 22/0/0 - 370/1(G3)/0 (AW1-AW9). Mirror 14/14.
"""

FULL_MESSAGES['1194fd8f'] = """\
v0.1.29+79: HalExtrasPanel - tighter row heights so the inverter temperature fits

Field: in the last row the inverter temperature label was clipped from below
by the edge of the Card. The height for three rows was marginally short.

Fix (height only, the 3x3 layout unchanged):
- row padding vertical 5 -> 3 (-12 px over three rows)
- height: 1.0 on the value and the label, removing the font's spare
  vertical reserve (~-4 px per cell), plus an explicit SizedBox(2) between
  them so they do not touch
- Card padding 12 -> 8 at the bottom and 12 -> 10 at the top, giving the
  last row more room

About -20 px in total, and the last row now fits completely.
TripMetricsPanel untouched. Data and decoders unchanged.
Version triplet -> 0.1.29+79.
"""

FULL_MESSAGES['12ae84fe'] = """\
v0.1.29+77: HalExtrasPanel in 3 columns with a smaller font - everything visible without scrolling

Field photo (+76 on the hardware): motor power, motor temperature and
inverter temperature went below the scroll line, so only 4 values were
visible. The real band is shorter than the nominal flex:3 (the power chart
in the top zone eats height), and 4 rows did not fit.

Fix: a 3-column grid arranged 3+3+1 (three rows instead of four), value
font 24 -> 18, unit and label -> 10, tighter padding. All 7 signals fit
without scrolling at 1280x800. Cells are still content-sized so they cannot
overlap, the value sits in a FittedBox (a long '2985.7' shrinks instead of
breaking the layout), and the label ellipsises. SingleChildScrollView is
kept only as insurance. TripMetricsPanel untouched.

Row layout: counter A, counter B, revolutions / torque, power, motor
temperature / inverter temperature.

Section design only - data, decoders and getters unchanged.
Version triplet -> 0.1.29+77.
"""

FULL_MESSAGES['fe83a2b0'] = """\
v0.1.29+76: HalExtrasPanel in 2 columns - fixing the collapsed section design

Field photo: the HAL motor section had slipped, with labels riding over
values. Cause (+75): four rows of Expanded TripCell inside a flex:3 band
sized for about two rows, so each row received roughly half the height it
needed and the lower label of one row covered the value of the next.

Fix: HalExtrasPanel is rewritten as a two-column grid of CONTENT-SIZED
cells (value on top, a small label beneath) - no vertical Expanded, so they
occupy only their own height and cannot overlap. Seven signals become four
rows (the second cell of the last row is empty), 12 dp between columns, thin
dividers. A long label is ellipsised and the value shrinks in a FittedBox
instead of pushing its neighbour. SingleChildScrollView as insurance.
TripMetricsPanel untouched.

Section design only - data, decoders and getters from +75 unchanged.
Version triplet -> 0.1.29+76, so the main screen shows this is the build
with the fix rather than the +75 in the photograph.
"""

LINE_SUBS = {
    'HU safety (К6, found by the critic pass): canUseHal is set by an ASYNC':
        'HU safety (K6, found by the critic pass): canUseHal is set by an ASYNC',

    '- Trends "Итоги за период": the 19 pt values painted across the cards\'':
        '- Trends period-totals card: the 19 pt values painted across the cards\'',

    '* Small labels: "HAL · MOTOR" → "MOTOR"/"МОТОР"; "Connect and start':
        '* Small labels: "HAL - MOTOR" becomes "MOTOR" in both locales; "Connect and start',

    '   Настройки → Автомобиль (between DTC and About) — idle/recording states,':
        '   Settings -> Vehicle (between DTC and About) - idle/recording states,',

    '  (English first as the default, Русский second).':
        '  (English first as the default, Russian second).',

    "  pattern). Countdown snackbar for the last 5 taps ('Ещё {n} тапов до":
        '  pattern). Countdown snackbar for the last 5 taps ("{n} taps left until',

    'default and can switch to Русский explicitly. Advanced previously':
        'default and can switch to Russian explicitly. Advanced previously',

    '  status-label switches, _relTime units). New "Язык / Language"':
        '  status-label switches, _relTime units). New "Language"',

    '  section between Автомобиль and Данные: 3 RadioListTile':
        '  section between the Vehicle and Data sections: 3 RadioListTile',

    '  (System/Русский/English) bound to LocaleService.setMode.':
        '  (System/Russian/English) bound to LocaleService.setMode.',

    '  Settings ↔ Дашборд/Ячейки/История/Настройки), HU rail':
        '  Settings, against their Russian counterparts), HU rail',

    '  (Driving/Vehicle/History/Settings ↔ Вождение/Автомобиль/История/':
        '  (Driving/Vehicle/History/Settings, against their Russian',

    '  Настройки).':
        '  counterparts).',

    '    Driver → Вождение · Analytics → Автомобиль · History → История':
        '    Driver, Analytics and History are renamed Driving, Vehicle and',

    "    Settings → Настройки · Native API → HAL Explorer (kept: it's the":
        "    History; Native API becomes HAL Explorer (kept: it's the",

    '  • Auto-push once per session, ONLY from tab 0 (Вождение / Dashboard).':
        '  - Auto-push once per session, ONLY from tab 0 (Driving / Dashboard).',

    '    Подключение / Стоимость / Облако / Автомобиль (DTC stays':
        '    Connection / Cost / Cloud / Vehicle (DTC stays',

    '    top-level — user feature) / Данные / Advanced (collapsed':
        '    top-level, a user feature) / Data / Advanced (collapsed',

    'locale framework (System/Русский/English, EN fallback) and migrate':
        'locale framework (System/Russian/English, EN fallback) and migrate',

    "    and a hardcoded 12-element array fallback ('янв'..'дек'). All":
        '    and a hardcoded 12-element array fallback of Russian month',

    '    helper; the hardcoded array is 12 entries with May=май (no':
        '    abbreviations; the hardcoded array is 12 entries (no',

    "  • Text fallback for <3 months — one bar isn't a chart; show 'май —":
        "  - Text fallback for <3 months - one bar isn't a chart; show a",

    "    The generic 'N точек · min-max' is replaced with one meaningful":
        '    The generic "N points, min-max" caption is replaced with one',

    "      Пробег накопительно   → 'итого N км · M поездок'":
        '      cumulative distance   -> total N km over M trips',

    "      Затраты по месяцам    → 'итого Br X · K мес'":
        '      monthly cost         -> total Br X over K months',

    "      Средний расход        → 'средн. X кВт·ч/100км · N поезд.' (weighted)":
        '      average consumption  -> mean X kWh/100km over N trips (weighted)',

    "      Доля рекуперации      → 'средн. X% · N поездок'":
        '      regeneration share   -> mean X% over N trips',

    "      SOH                   → 'было X% → сейчас Y% · N точек'":
        '      SOH                  -> was X%, now Y%, over N points',

    "      Реальный запас на 100%→ 'средн. X км · последняя Y км · N точек'":
        '      real range at 100%   -> mean X km, last Y km, N points',

    '"История пропусков" — this exact failure mode happened multiple':
        'the misses-history table - this exact failure mode happened multiple',

    ' - New top-level "Pre-flight" section between "Регрессионное тестирование"':
        ' - New top-level "Pre-flight" section between the regression-testing',

    '   and "Установка APK без ADB". Subsections cover:':
        '   section and the no-ADB APK installation section. Subsections cover:',

    '     * История пропусков table with five rows now (added v0.1.29+5 row)':
        '     * the misses-history table with five rows now (v0.1.29+5 added)',

    'Проводник and copied to a USB flash drive without ADB. Replaces the':
        "the head unit's stock file manager and copied to a USB flash drive"
        ' without ADB. Replaces the',

    "  Field test also showed the 'CHARGING подключена' label flickering":
        '  Field test also showed the charging-connected label flickering',

    "  disconnected, msg: 'BLE отключился (вне зоны / адаптер выключен)').":
        '  disconnected, with a message saying BLE dropped because the adapter'
        ' is out of range or switched off).',

    "- New 'Подключиться к последнему адаптеру' button — useful when auto-":
        '- New "connect to the last adapter" button - useful when auto-',

    "'Проводник' file manager, from where the user can copy to USB flash.":
        "the head unit's stock file manager, from where the user can copy to"
        ' USB flash.',

    "  'Поделиться' (filled)  → share sheet (phone-friendly)":
        '  Share (filled button)  -> share sheet (phone-friendly)',

    "  'Сохранить в Downloads' (outlined) → direct write (head unit)":
        '  Save to Downloads (outlined) -> direct write (head unit)',

    "'Найти адаптер' returned other random BLE peripherals instead of the":
        'the find-adapter action returned other random BLE peripherals instead'
        ' of the',
}


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

def git(*args):
    out = subprocess.run(('git',) + args, capture_output=True, text=True)
    if out.returncode:
        sys.exit('git %s failed: %s' % (' '.join(args), out.stderr.strip()))
    return out.stdout


def resolve(prefix):
    """Expand an abbreviated SHA, failing loudly on ambiguity."""
    full = git('rev-parse', '--verify', '%s^{commit}' % prefix).strip()
    if len(full) != 40:
        sys.exit('cannot resolve %s' % prefix)
    return full


def rewrite(message):
    """Apply TOKEN_SUBS and LINE_SUBS to one message."""
    for old, new in TOKEN_SUBS:
        message = message.replace(old, new)
    lines = message.split('\n')
    for i, line in enumerate(lines):
        key = line.rstrip()
        if key in LINE_SUBS:
            lines[i] = LINE_SUBS[key]
    return '\n'.join(lines)


def build_map():
    """original full SHA -> new message, for every commit that changes.

    Returns the mapping and the set of SHAs served from FULL_MESSAGES, so
    the report counts replacements that actually landed rather than the
    size of the table.
    """
    full = {resolve(p): m for p, m in FULL_MESSAGES.items()}
    mapping = {}
    whole = set()
    raw = git('log', '--reverse', '--format=%H%x1f%B%x1e')
    for record in raw.split('\x1e'):
        record = record.strip('\n')
        if not record:
            continue
        sha, _, body = record.partition('\x1f')
        new = full[sha] if sha in full else rewrite(body)
        if new.rstrip('\n') != body.rstrip('\n'):
            mapping[sha] = new.rstrip('\n') + '\n'
            if sha in full:
                whole.add(sha)
    unused = sorted(s[:8] for s in set(full) - whole)
    if unused:
        sys.exit('FULL_MESSAGES entries changed nothing: %s' % ', '.join(unused))
    return mapping, whole


def purge_targets():
    """PURGE_PATHS still reachable from some ref, with commit counts."""
    hits = {}
    for path in PURGE_PATHS:
        out = git('log', '--all', '--format=%H', '--', path).strip()
        n = len([l for l in out.split('\n') if l])
        if n:
            hits[path] = n
    return hits


def check_backup(path):
    """Confirm a copy of the catalogue exists outside this repository."""
    if path is None:
        sys.exit('--backup is required while the catalogue is still in history.\n'
                 '  git show HEAD:%s > ~/bz5_feature_catalog.csv' % PURGE_PATHS[0])
    real = os.path.realpath(path)
    inside = os.path.realpath(git('rev-parse', '--show-toplevel').strip())
    if real.startswith(inside + os.sep):
        sys.exit('backup %s is inside the repository - the purge would take it '
                 'with everything else; put it elsewhere' % real)
    try:
        data = open(real, 'rb').read()
    except OSError as exc:
        sys.exit('cannot read backup %s: %s' % (real, exc))
    got = hashlib.sha256(data).hexdigest()
    if len(data) != CATALOGUE_BYTES or got != CATALOGUE_SHA256:
        sys.exit('backup does not match the catalogue in history\n'
                 '  expected %d bytes sha256 %s\n'
                 '  got      %d bytes sha256 %s'
                 % (CATALOGUE_BYTES, CATALOGUE_SHA256, len(data), got))
    print('backup verified:          %s' % real)


def report(mapping, whole):
    total = int(git('rev-list', '--count', 'HEAD').strip())
    raw = git('log', '--format=%H%x1f%B%x1e')
    left = []
    for record in raw.split('\x1e'):
        record = record.strip('\n')
        if not record:
            continue
        sha, _, body = record.partition('\x1f')
        text = mapping.get(sha, body)
        for line in text.split('\n'):
            if CYRILLIC.search(line):
                left.append((sha[:8], line.strip()))
    print('commits on HEAD:          %d' % total)
    print('messages to be rewritten: %d' % len(mapping))
    print('  of them replaced whole: %d' % len(whole))
    print('russian lines remaining:  %d' % len(left))
    hits = purge_targets()
    if hits:
        for path, n in sorted(hits.items()):
            print('to purge from history:    %s (%d commits)' % (path, n))
    else:
        print('to purge from history:    nothing, already absent')
    for sha, line in left[:40]:
        print('  %s | %s' % (sha, line[:110]))
    if len(left) > 40:
        print('  ... and %d more' % (len(left) - 40))
    return not left


def run(mapping):
    try:
        import git_filter_repo as fr
    except ImportError:
        sys.exit('git-filter-repo is required: pip install git-filter-repo')

    encoded = {k.encode(): v.encode() for k, v in mapping.items()}

    def commit_callback(commit, metadata):
        new = encoded.get(commit.original_id)
        if new is not None:
            commit.message = new

    # git-filter-repo deletes the remote named `origin` in full mode, on
    # purpose, so that a rewrite cannot be pushed by accident. We want the
    # push to be deliberate but not hand-typed: remember the URL and put the
    # remote back afterwards, so nobody re-adds it with a typo.
    origin = subprocess.run(('git', 'remote', 'get-url', 'origin'),
                            capture_output=True, text=True).stdout.strip()

    argv = ['--force', '--replace-refs', 'delete-no-add']
    hits = purge_targets()
    if hits:
        argv.append('--invert-paths')
        for path in PURGE_PATHS:
            argv += ['--path', path]
    # No --refs: every ref is rewritten, tags included. Tags have to move or
    # the purged blob stays reachable through them.
    args = fr.FilteringOptions.parse_args(argv)
    fr.RepoFilter(args, commit_callback=commit_callback).run()

    print('rewrote %d messages' % len(mapping))
    if hits:
        print('purged %d path(s) from every ref' % len(hits))

    if origin:
        have = subprocess.run(('git', 'remote'), capture_output=True,
                              text=True).stdout.split()
        if 'origin' not in have:
            subprocess.run(('git', 'remote', 'add', 'origin', origin),
                           check=True)
            print('restored remote origin -> %s' % origin)
    else:
        print('no remote named origin was configured; add one before pushing')

    print('now:  git push --force origin main')
    print('      git push --force --tags')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check', action='store_true',
                       help='report what would change, write nothing')
    group.add_argument('--run', action='store_true',
                       help='rewrite every ref in place')
    parser.add_argument('--backup', metavar='PATH',
                        help='copy of the feature catalogue kept outside this '
                             'repository; required by --run while the file is '
                             'still in history, because the purge prunes it '
                             'locally too')
    opts = parser.parse_args()

    mapping, whole = build_map()
    clean = report(mapping, whole)
    if opts.check:
        return 0 if clean else 1
    if not clean:
        sys.exit('refusing to run: russian lines would remain (see above)')
    if git('status', '--porcelain').strip():
        sys.exit('working tree is dirty - commit or stash first')
    if purge_targets():
        check_backup(opts.backup)
    run(mapping)
    return 0


if __name__ == '__main__':
    sys.exit(main())
