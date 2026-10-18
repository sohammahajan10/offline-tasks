# Demo video script (about 4 minutes)

Two Android emulators side by side, both signed in to the same account, with
the Supabase table editor open in a browser.

## Before recording

```sh
# Release APK with your Supabase keys
flutter build apk --release --dart-define-from-file=.env

# A second emulator (the first is offline_tasks_api35)
avdmanager create avd -n offline_tasks_b -k "system-images;android-35;google_apis;x86_64" -d pixel_7
emulator -avd offline_tasks_api35 &
emulator -avd offline_tasks_b &

# Install on both (check the serials with: adb devices)
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s emulator-5556 install -r build/app/outputs/flutter-apk/app-release.apk

# Airplane mode from the terminal, if the quick-settings tile is fiddly:
adb -s emulator-5554 shell cmd connectivity airplane-mode enable    # or disable
```

- Sign in to the demo account on both emulators. Call them **A** (left) and
  **B** (right).
- In the Supabase dashboard, open **Table editor → tasks**, sorted by
  `server_updated_at` descending.
- Start from an empty task list: delete old demo tasks, or use a fresh account.

---

## 0:00 Intro (15 s)

> "This is an offline-first task manager. Everything is written to a local
> SQLite database first, so the UI never waits for the network. A sync engine
> pushes an outbox of changes to Supabase and pulls other devices' changes."

Show A's empty list, with the cloud icon showing a tick (synced).

## 0:15 Working offline (45 s)

1. On **A**, turn on **airplane mode**.
   > "The banner appears because a real request to the server fails, not just
   > because Wi-Fi went off."
2. Create **Pay rent**: High priority, deadline tomorrow, category *Home*, tag
   *bills*. Create **Buy milk**.
3. Tick **Pay rent** done. Swipe **Buy milk** away and tap **Undo**.
   > "Each task shows a waiting-to-sync badge, and the banner counts the
   > changes. Edits made offline are merged into one queue entry per task."
4. Search for *rent*, then filter by **Done**, then clear the filters.

## 1:00 Survive a force-stop (25 s)

1. Settings → Apps → Offline Tasks → **Force stop** (or swipe A away from
   recents).
2. Reopen A, still in airplane mode.
   > "The tasks and the queue are still there. Each change was written to the
   > task table and the outbox in one transaction, so a crash can't separate
   > them."

## 1:25 Reconnect (30 s)

1. Turn airplane mode **off** on A.
   > "Coming back online triggers a sync on its own. The badges clear."
2. Switch to the **Supabase table editor** and refresh: both rows are there,
   with *Pay rent* `completed = true` and its `version` incremented.
3. Open **⋮ → Sync log** on A: *Uploaded "Pay rent"*, *Uploaded "Buy milk"*,
   and *Sync finished*.

## 1:55 Two-device conflict (75 s)

1. On **B**, tap the cloud button. *Pay rent* and *Buy milk* appear (a delta
   pull of rows changed since its last cursor).
2. Turn on airplane mode on **both** A and B.
3. On **A**: rename *Buy milk* to **Buy oat milk**.
   On **B**: set *Buy milk* to **High** priority and tick it **done**.
   > "Both devices changed the same task while offline, but different fields."
4. Turn **A** online and wait for the tick, then turn **B** online.
   > "B's push is rejected as stale: the server's version moved. B merges
   > three ways against the last version both devices agreed on, so A's new
   > title and B's priority and done state all survive. Then it re-pushes."
5. Show both screens: **Buy oat milk**, High, done, on A and B.
   B's Sync log: *"Buy milk" changed on the server … merging* and *Merged
   server changes into "Buy oat milk"*.
6. Same-field conflict, quickly: both offline. On A, rename to *Oat milk
   (A)*; a few seconds later on B, rename to *Oat milk (B)*. Bring both online.
   > "Both edited the title. The later edit wins, here B's, on both devices,
   > and the Sync log records the conflict and which side was kept. That
   > timestamp comes from the device clock, which is the trade-off of
   > last-writer-wins."

## 3:10 Bonus features (40 s)

1. **Recurring**: create *Water plants*, deadline today, Repeat **Weekly**.
   Put both devices offline and tick it off on **both**. Bring both online.
   > "Each device created next week's occurrence with the same id, a UUIDv5 of
   > the series and the due date, so after sync there is exactly one."
2. **Reorder**: sort menu → **Manual (drag)**, then drag a task by its
   handle. On B, sync: the same order.
   > "Only the moved task gets a new fractional sort key, so a reorder is one
   > small change."
3. **Reminder**: point at the reminder for *Water plants*, or show one fired
   earlier, in the notification shade.

## 3:50 Wrap-up (10 s)

> "Local-first writes, a transactional outbox, idempotent pushes enforced by
> the database, backoff with jitter, and a three-way merge that keeps
> non-conflicting edits from both devices."

---

### If something goes wrong on camera

- **Nothing syncs after reconnecting**: tap the cloud button. Sync also runs
  on resume, and every minute while online.
- **B doesn't show A's change**: tap the cloud button on B. B pulls on resume
  and every minute.
- **A change shows a red badge**: open the Sync log. The entry shows the
  error, with a **Retry** button.
