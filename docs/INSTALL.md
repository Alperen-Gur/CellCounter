# Installing CellCounter

## macOS

CellCounter v1.0 is a native macOS app. It is **ad-hoc signed but not yet
notarized**, so macOS Gatekeeper will warn you the first time you open it. This
is expected; here's how to get past it.

### Step by step

1. **Download** the latest `CellCounter-<version>.zip` from the
   [Releases page](https://github.com/Alperen-Gur/CellCounter/releases).
2. **Unzip** it (double-click) and drag **CellCounter.app** into **Applications**.
   If you're replacing an older copy, delete the old one first.
3. **Double-click** CellCounter. macOS will say it "cannot be opened because
   Apple cannot check it for malicious software." Click **Done** (do not move it
   to Trash).
4. Open **System Settings → Privacy & Security**. Scroll to the bottom — you'll
   see a line about CellCounter being blocked. Click **Open Anyway**.
5. Double-click CellCounter again. Confirm with **Open**. From now on it opens
   normally.

### Setting up the segmentation engine

The app ships without the Python environment (it's large and platform-specific),
so the first time you want to run detection:

1. Go to the **Models** tab.
2. Click **Install Cellpose…**.
3. Wait for the install to finish — it downloads Python packages and the model
   weights, takes a few minutes, and only happens once. The lower part of the
   dialog shows a live log; if anything fails, that log is what to screenshot in
   a bug report.

### Why isn't it notarized / on the App Store?

Notarization needs a paid Apple Developer account. For a research tool shared
with a handful of labs, the "Open Anyway" step above is the pragmatic path. If
this sees wider use, notarization is on the list.

## Windows / Linux

Not available yet — the cross-platform build is in progress. See the Roadmap in
the [README](../README.md).

## Delivery note for institutional email

Some university mail servers reject `.app` bundles and `.zip` files that contain
them, even when everything is legitimate. If you're
sending CellCounter to a colleague, use a file-share link (institutional cloud,
Sciebo, WeTransfer) rather than an email attachment.
