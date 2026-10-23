# Changelog

## 0.1.0 – unreleased

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
