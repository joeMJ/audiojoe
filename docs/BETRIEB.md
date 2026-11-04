# audiojoe sicher betreiben

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). Die im
Server eingebauten Hilfeseiten unter `/docs/` passen immer zur installierten Version.*

Empfehlungen für den dauerhaften Betrieb: welche Ports offen sein müssen, wie Container und Dienst
eingeschränkt sind, Konten, Updates und der Weg zurück, und was gilt, wenn audiojoe aus dem
Internet erreichbar ist. Welche Bibliotheken vor der Anmeldung antworten, steht unter
[Über HTTPS erreichbare Bestandteile](SECURITY-COMPONENTS.md); Sicherungen unter
[Sicherung und Wiederherstellung](BACKUP.md).

## Was erreichbar sein muss

| Port | Von wo | Wofür |
|---|---|---|
| `listen` (8080 bei den Skripten) | **nur vom Reverse Proxy** | Apps und Web-Player, über den Proxy mit HTTPS |
| `[sonos] listen` (8081) | **nur aus dem Heimnetz** (die Lautsprecher) | Sonos holt den Ton; nie im Proxy weiterleiten |
| ausgehend HTTPS | ins Internet | Quellen, Podcast-Feeds, Radio Browser, fyyd, MusicBrainz, GitHub (Updates), Debian-Spiegel |

Sonst muss nichts herein. TLS macht der Proxy; audiojoe selbst spricht nur HTTP.

## Firewall im Container (nftables)

Beispiel für `/etc/nftables.conf`; die Adresse deines Proxys und dein Heimnetz eintragen:

```
#!/usr/sbin/nft -f
# audiojoe: only the proxy reaches the server, only the home network the Sonos port.
flush ruleset

define PROXY = 10.0.0.5          # address of the reverse proxy
define HOME  = 10.0.0.0/24       # home network (Sonos speakers, SSH)

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    tcp dport 22   ip saddr $HOME  accept   # SSH, only if used
    tcp dport 8080 ip saddr $PROXY accept   # audiojoe-server (listen)
    tcp dport 8081 ip saddr $HOME  accept   # Sonos stream port ([sonos] listen)
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
  }
}
```

```bash
sudo apt install nftables            # im Debian-Container schon vorhanden
sudo nft -c -f /etc/nftables.conf    # nur prüfen
sudo systemctl enable --now nftables
sudo systemctl restart nftables      # neue Regeln laden
```

Ausprobiert in einem unprivilegierten Debian-13-Container (auch nach einem Neustart): Der Proxy
erreicht den Server, andere Rechner nicht; der Sonos-Port antwortet im Heimnetz; Updates und die
Verbindungen zu den Quellen funktionieren weiter. Mit `IP=dhcp` müssen zusätzlich die Antworten des
DHCP-Servers erlaubt sein (`udp dport 68 accept`; nicht ausprobiert). Statt nftables im Container
kann auch die [Proxmox-Firewall](https://pve.proxmox.com/wiki/Firewall) (englisch) den Verkehr des
Containers filtern.

## Container und Dienst

- **Container:** Das Proxmox-Skript legt einen **unprivilegierten** Container an: root im Container
  ist nicht root auf dem Host. Ohne root-Kennwort (Vorgabe des Skripts) kommt man nur über die
  Proxmox-Konsole in den Container; root-Anmeldung über SSH ist aus, solange du sie nicht
  einschaltest.
- **Dienst:** `audiojoe-server` läuft als eigener Nutzer `audiojoe` ohne Sonderrechte. systemd
  schränkt ihn weiter ein (`packaging/deb/audiojoe-server.service`): Er darf nur nach
  `/var/lib/audiojoe` schreiben, sieht keine Home-Verzeichnisse und Geräte, hat keine Capabilities,
  darf keinen ausführbaren Speicher anlegen und nutzt nur Netz und lokale Sockets.
  `systemd-analyze security audiojoe-server` bewertet ihn mit 1,4 („OK“; die Skala reicht von 0
  bis 10, kleiner ist besser).
- **Dateien:** Datenbank und WAL nur für `audiojoe` (`600`), `config.toml` nur für root und die
  Gruppe `audiojoe` (`640`).
- **Updates des Systems:** `unattended-upgrades` installiert täglich die Debian-Updates
  ([Updates und Pflege](install-server.md#updates-und-pflege)).
- **Proxmox-Host:** gehört nicht zu audiojoe. Aktuell halten und Weboberfläche (Port 8006) sowie
  SSH nur aus dem Netz erreichbar machen, aus dem du verwaltest; siehe die
  [Proxmox-VE-Dokumentation](https://pve.proxmox.com/pve-docs/pve-admin-guide.html) (englisch).

## Konten und Zugangsschlüssel

- **Ein Konto je Person** (`audiojoe-server user add <name>`, siehe
  [Erste Schritte](ERSTE-SCHRITTE.md#benutzer-anlegen)). Jede Anmeldung braucht Kennwort **und** den
  Code der Authenticator-App; abschalten lässt sich das nicht.
- **Gerät verloren:** in der App unter **Einstellungen → Geräte** dieses Gerät abmelden. Ein neues
  Kennwort (`audiojoe-server user passwd <name>`) oder ein neues Authenticator-Geheimnis
  (`audiojoe-server user totp-reset <name>`) beendet alle Anmeldungen dieses Nutzers.
- **Podcast-Apps** (gpodder-Abgleich) bekommen ein eigenes **App-Kennwort**; es gilt nur für den
  Abgleich, nicht für die Anmeldung ([Anleitung](ANLEITUNG.md)).
- **Quellen:** audiojoe einen eigenen Nutzer mit nur den nötigen Rechten geben – lesen; bei
  Audiobookshelf zusätzlich den Hörstand speichern. Sein Zugangsschlüssel liegt nur auf dem Server.

## Updates und der Weg zurück

- **Automatisch:** jede Nacht um 04:00 mit Sicherung vorher und automatischem Weg zurück, wenn die
  neue Version nicht startet ([Updates und Pflege](install-server.md#updates-und-pflege)). Wer
  vorher entscheiden will, stellt in der App auf **Nur melden**.
- **Von Hand auf eine ältere Version** – etwa wenn eine neue Version läuft, aber nicht wie erwartet
  arbeitet:

  ```bash
  V=0.1.6                                   # die gewünschte Version
  cd /tmp
  curl -fsSLO https://github.com/joeMJ/audiojoe/releases/download/v$V/audiojoe-server_${V}_amd64.deb
  curl -fsSLO https://github.com/joeMJ/audiojoe/releases/download/v$V/SHA256SUMS
  sha256sum -c --ignore-missing SHA256SUMS  # muss „OK“ melden
  sudo systemctl stop audiojoe-server
  sudo apt-get install --allow-downgrades ./audiojoe-server_${V}_amd64.deb
  ```

  Danach die Datenbank-Sicherung von **vor** dem Update auf die neuere Version zurückspielen
  (`/var/backups/audiojoe/audiojoe-<alte-version>-<zeit>.db`, siehe
  [Zurückspielen auf demselben Server](BACKUP.md#zurückspielen-auf-demselben-server)): Ein älterer
  Server kennt die Änderungen nicht, die eine neuere Version an der Datenbank gemacht hat. Auf
  **Nur melden** stellen oder den Timer anhalten (`systemctl disable --now audiojoe-update.timer`),
  sonst kommt die neuere Version in der nächsten Nacht wieder.

## Aus dem Internet erreichbar

Ohne Anmeldung erreichbar ist wenig: die Seiten des Web-Players, die Hilfeseiten,
`/api/v1/health`, die Anmeldung und die gpodder-Pfade (ohne App-Kennwort antworten sie nur
„unauthorized“); Einzelheiten unter [Über HTTPS erreichbare Bestandteile](SECURITY-COMPONENTS.md).
Trotzdem:

- **Brauchst du es?** Hörst nur du von unterwegs, ist ein VPN ins Heimnetz die kleinere
  Angriffsfläche; dann muss der Proxy gar nicht aus dem Internet erreichbar sein.
- **Zugriff begrenzen:** im Proxy auf bekannte Netze (eine Access List, z. B. dein Mobilfunkanbieter
  und dein Heimanschluss) und nur HTTPS.
- **Nie** den Sonos-Port weiterleiten.
- **Aktuell halten:** das nächtliche Update eingeschaltet lassen; eine Schwachstelle in einer der
  vor der Anmeldung erreichbaren Bibliotheken ist ein Grund, bald zu aktualisieren.
- **Protokoll ansehen:** `journalctl -u audiojoe-server` zeigt je Anfrage IP-Adresse, Methode, Pfad,
  Status und Dauer (14 Tage aufbewahrt); viele `401` auf `/api/v1/auth/login` heißen, dass es
  jemand versucht. Nach 5 fehlgeschlagenen Anmeldungen innerhalb von 15 Minuten – je IP-Adresse und
  je Nutzername – antwortet der Server für den Rest dieser Zeit mit `429`.
