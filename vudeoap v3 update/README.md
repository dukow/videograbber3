# Video Grabber 4 (videograbber3 repo)

Browse, sniff and download videos fully on-device — now with **foreground-service
downloads** so 2-hour videos finish completely, even with the screen off or the
app closed.

## What's new vs videograbber2 (why long videos failed before)

The old app ran yt-dlp in a plain background thread inside the Activity.
Android killed it when the screen turned off → big videos stopped at 30-60%.

Fixed in this version:

| Fix | What it does |
|---|---|
| Foreground service + notification | Android never kills the download |
| Wake lock + WiFi lock (up to 6h) | CPU and WiFi stay awake |
| `--continue` + Resume button | Dropped internet resumes, never restarts from 0 |
| `--retries 20 --fragment-retries 50` | Survives bad connections |
| `--concurrent-fragments 8` | HLS episodes download much faster |
| Battery exemption button | Stops aggressive battery savers (recommended for 2h videos) |
| Download queue screen | Progress %, ETA, cancel, resume per item |

## Sources

- **Browser sniffer**: open any site (Dailymotion, DramaBox web, ReelShort,
  GoodShort, mini-drama sites), press play, tap the floating download button —
  every `.m3u8` / `.mp4` stream the page loads is caught.
- **Paste link**: Dailymotion, YouTube, TikTok, Facebook, X, and 1000+ sites
  supported by yt-dlp, plus any direct m3u8/mp4 link.
- **DramaBox note**: the DramaBox *app's* VIP episodes are DRM-protected and
  cannot be downloaded by any app. Episodes that play in the built-in browser
  (web version / free episodes) CAN be sniffed and downloaded.

## Build (no PC setup needed)

Everything builds on GitHub Actions:

1. Create a new GitHub repo (e.g. `videograbber3`).
2. Upload all files from this folder (keep the folder structure, including
   `.github/workflows/build.yml`).
3. Go to the **Actions** tab → the "Build APK" workflow starts automatically.
4. Wait ~10-15 minutes for the green check.
5. Open the finished run → scroll to **Artifacts** → download
   **VideoGrabber-APK** → unzip → install `app-release.apk`.

Files download to `Downloads/VideoGrabber` on the phone.

## First run on the phone

1. Allow notifications + file access when asked.
2. In the **Grab** tab, tap **"Allow background downloads"** and accept —
   this is important for 1-2 hour videos.
3. If a site stops working someday, tap **"Update download engine"**.
