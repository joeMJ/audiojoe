# Install audiojoe on Ubuntu

*This page describes the current release. For an older version, see the same page under that
version's tag on GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). The help pages
built into your server under `/docs/` always match the installed version.*

For Ubuntu 24.04 and 26.04 (amd64) there is one package (`.deb`); the same package also fits
[Debian 13](install-debian.en.md). The app needs an audiojoe server
([Install the server](install-server.en.md)). The easiest way: the script installs the package
from the newest release:

```bash
curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/install.sh | bash
```

The script checks the Ubuntu version and the architecture, downloads the package and the file
`SHA256SUMS`, checks the checksum and installs with `sudo apt-get install`. The same command
updates an existing installation.

**Read first, then run** (recommended): the one-liner above runs the script without you seeing it
first. If you do not want that, download it first, read it and then start it:

```bash
curl -fsSL -o install-audiojoe.sh https://raw.githubusercontent.com/joeMJ/audiojoe/main/install.sh
less install-audiojoe.sh
bash install-audiojoe.sh
```

By hand: download the package `audiojoe_<version>_amd64.deb` from the
[release page](https://github.com/joeMJ/audiojoe/releases/latest) (not `audiojoe-server_…`, that is
the server), compare the checksum with `SHA256SUMS` and install it:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo apt install ./audiojoe_<version>_amd64.deb
```

audiojoe then shows up in the application menu; in a terminal it starts with `audiojoe`. Playback
uses `libmpv2` from the system, the sign-in is kept in the keyring (`libsecret`); apt installs both.

Remove:

```bash
sudo apt remove audiojoe
```

Positions, offline titles and settings stay in `~/.local/share/io.github.joemj.audiojoe/`, the
sign-in in the keyring.

## Updates

If the server is installed from the package, the app shows a new version under
**Settings → Maintenance** in the row **App**. **Download version …** downloads the package through
your own server and checks it against `SHA256SUMS` of the same release; if the checksum does not
match, nothing is installed. Then the app shows the command `pkexec apt-get install -y …`, installs
after **Install** (the system asks for the password) and offers **Restart**.
The app never asks GitHub for this, see [Privacy](DATENSCHUTZ.en.md#updates-only-with-the-server-package).
The installation command above updates as well.

## From source

In the folder `clients/app` run `flutter build linux --release`, then `../../tools/build-deb.sh` –
this makes a `.deb`.
