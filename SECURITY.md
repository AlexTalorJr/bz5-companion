# Reporting a vulnerability

Please report security problems privately rather than in a public issue.

Use GitHub's private vulnerability reporting on this repository: open the
**Security** tab and choose **Report a vulnerability**. That channel keeps the
report confidential until a fix is available, and it needs no email address
from either side.

What is useful in a report: the app version (visible on the About screen and
stamped into every diagnostic dump), whether you were on a head unit or a
phone, and what an attacker would be able to do. A diagnostic export helps,
but please look through it first — it contains your trips, your odometer and
your VIN.

## Scope

In scope: this app, its native head-unit layer, and the credentials it stores
on the device. The cloud bridge is a separate project; a problem there is
still worth reporting here and will be passed on.

Out of scope: the vehicle's own firmware and the BYD framework.

One thing worth stating precisely, because it is the highest-consequence part
of this codebase. The app as shipped never writes to the vehicle: every read
path is a subscription or a diagnostic read. A property-write call does exist
in the native layer — `BydCarPropertyClient.setProperty` — because the BYD
framework exposes one, but nothing calls it and no screen reaches it. If you
find a path by which that call becomes reachable, or any other way this app
could change how the vehicle behaves, that is the most important kind of
report and should come first.

## Expectations

This is a one-person project maintained in spare time. Reports are read, but
there is no service-level commitment and no bounty.
