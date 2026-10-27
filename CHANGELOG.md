# Changelog

## Unreleased

- Menu bar: Settings › Menu bar › “Time in the menu bar” chooses what stands next to the icon:
  “Automatic” (the running timer, otherwise today's project time), the running timer only,
  today's project time with the running timer counted, today's attendance, or the icon only. A
  stopwatch marks the running timer, a clock today's project time, a person the attendance;
  pointing at the icon lists all of today's times in a tooltip. Whoever had switched off “Show
  running timer” keeps the icon only, everyone else gets “Automatic”. With only attendance
  switched on, the menu bar shows today's attendance.
- Stopping never discards the time: under a minute it goes to the form with the measured
  duration, at least 0:01, like a timer without a project; book it there or discard it with the
  trash. Until then no new timer starts. Starting another timer still discards a running one
  that is under a minute.

## 0.3.0 – 2026-10-27

- Timer: “Start” at the top of the window starts the time right away; project, task and
  description can be chosen while it runs (click the project line) or when stopping, where the
  form books it with the measured duration. Without a duration, “Start” in the form starts the
  time for project, task and description; ▶ on an entry (or “Start Again” in its context menu)
  starts the same work again. One timer at a time: starting another books the running one, and a
  timer without a project needs one first. Stop books right away on the day the timer started,
  rounded as set; under a minute nothing is booked. The trash discards it after a confirmation,
  and it keeps running when the app quits. If booking fails, the time stays stopped until a retry
  succeeds.
- The menu bar shows only the clock icon, and the running timer's hours and minutes next to it.
  Attendance and the green dot are no longer shown there; checking in and out stays in the
  window. Settings › Menu bar has one switch, “Show running timer”.
- Rounding is now a choice in the settings: don't round, 15 minutes, 30 minutes or 1 hour, to
  the nearest unit and never to zero. New installations don't round; the former switch “Round
  durations to quarter hours” becomes 15 minutes, so existing users keep what they had. The − and
  + buttons step by the chosen unit, without rounding by 15 minutes.
- Fixed: at smaller sizes, as in the Dock or in Finder, the app icon had a grey box around its
  tile.

## 0.2.0 – 2026-10-24

- New app icon in Odoo's purple: a stopwatch whose teal segment shows the booked time.
- Edit entries: a click opens an entry in the form below, including its date; delete after a
  confirmation inside the window. Invoiced entries keep everything but the description, as in
  Odoo; validated ones (Odoo Enterprise) are read-only. Closed tasks and archived projects of an
  entry stay as they are.
- Correct attendance: change start and end, move a break, add a forgotten period, delete one,
  with the same checks as Odoo (order, overlaps, nothing in the future). Periods that Odoo ended
  automatically are marked for correcting. Needs the same right as checking in.
- Several companies in one database: projects grouped by company, a day's entries with
  subtotals per company, the booking company shown in the form. When a project moves an entry to
  another company, the app switches it to the user's employee there, as Odoo does when creating.
  Users with employees in several companies choose in the settings where they check in.
- Optional module “Arbeitszeitgesetz”: the app recognises breaks inserted by Odoo, explains
  whether a moved break is long enough and reports what Odoo added after saving.
- Fixed: signing in to Odoo 18 failed with a redirect notice. Odoo 18 answers the JSON-2 probe
  with a redirect to its login page; the app now takes that as “no JSON-2” and continues with
  JSON-RPC, still without following the redirect.
- Changes are sent to Odoo 17 and 18 with the values as a positional argument, because some
  models there name the parameter of `write` differently.

## 0.1.0 – 2026-10-23

First version.

- Menu bar app for macOS 14 and newer: today's booked hours and/or attendance in the menu bar,
  green dot while checked in.
- Timesheets: project with search and recently used projects, task, description, duration
  (`1:30`, `1,5`, `90 min`, optionally rounded to quarter hours); entries of a day with total,
  browse and book earlier days.
- Attendance: check in and out, today's periods and breaks, time not yet booked on projects.
- Functions can be switched on separately; the app checks which Odoo apps are installed and
  whether the user may check in via the API.
- Odoo 19 via JSON-2, Odoo 17 and 18 via JSON-RPC; API key in the Keychain.
- Never follows server redirects, so the API key only goes to the configured address.
- Copes with unreliable connections: retries on its own with growing intervals, keeps showing
  what could be loaded, and does not book an entry twice when Odoo's response gets lost.
- Hides check-in when Odoo refuses it despite the access right reported by the API (attendance
  officers who are not their own attendance approver).
- Distributed as a DMG with the usual drag-to-Applications window; releases are signed with a
  Developer ID and notarized by a GitHub Actions workflow.
- Updates via Sparkle: a daily check, a gentle hint in the menu bar window, installation and
  relaunch on click; only updates signed with the project's key are accepted.
- Opens at login by default when started from the Applications folder for the first time.
- Light and dark appearance, keyboard shortcuts, VoiceOver labels.
- German, English and French, following the language of the Mac; dates and times in the format
  of the Mac's region. Durations also accept English and French units (`2 hours`, `1 heure 30`).
- Demo mode: the server `demo` shows invented data held in memory, to try the app without Odoo.
- Separate build for the Mac App Store: updates through the App Store instead of Sparkle, and
  opening at login stays off until the user turns it on.
