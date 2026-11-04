# Install audiojoe on Android

*This page describes the current release. For an older version, see the same page under that
version's tag on GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). The help pages
built into your server under `/docs/` always match the installed version.*

**Requirements:** Android 7.0 or later. The app needs an audiojoe server
([Install the server](install-server.en.md)). audiojoe is not in the Play Store; you install the
signed APK from the release.

**Install:**

1. On the phone open the [release page](https://github.com/joeMJ/audiojoe/releases/latest) and
   download `audiojoe-<version>.apk`.
2. Open the file (notification of the browser or the Files app).
3. The first time, Android asks whether this app (browser or Files) may **install unknown apps**:
   allow it in the settings, go back, **Install**. On Android 7 the setting is called
   **Unknown sources** (Settings → Security).
4. Afterwards switch the permission for the browser or Files off again if it is not needed.

**Check that it is genuine** (recommended, on a computer): download the APK and `SHA256SUMS` from
the release into one folder and compare the checksum; `apksigner` from the Android build tools
shows the signature:

```bash
sha256sum -c --ignore-missing SHA256SUMS
apksigner verify --print-certs audiojoe-<version>.apk
```

Expected: `CN=audiojoe, O=joeMJ` and as the certificate's SHA-256
`60f91d92d6ff259a5c9f811cd47df8388016c7aeace642af89acd74c73fedc12`. Android accepts later
versions as an update only with the same signature.

> [!NOTE]
> Google Play Protect may warn about apps from outside the Play Store. Check that it is genuine
> first (above), then decide.

**Update:** if the server is installed from the package, the app shows a new version under
**Settings → Maintenance** in the row **App**. **Install version …** downloads the APK through your
own server and opens the package installer; the first time Android asks whether audiojoe may
install apps, and it asks before every installation. The app never asks GitHub for this, see
[Privacy](DATENSCHUTZ.en.md#updates-only-with-the-server-package). By hand: install the new APK as
above.

**Uninstall:** Settings → Apps → **audiojoe** → **Uninstall**. Android also removes the sign-in,
the positions on the device and the offline titles; the positions on the server stay.

## From source

```bash
cd clients/app && flutter build apk --release --flavor github
```

This build checks for new versions through your own server, like the APK in the release. For
F-Droid there is a build without the update check:

```bash
flutter build apk --release --flavor fdroid --dart-define=AUDIOJOE_DIST=fdroid
```
