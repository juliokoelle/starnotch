# „Taras Gedächtnis ist pausiert …“ bei Jamie, Granola und Wispr Flow, obwohl nichts pausiert ist

Beta-Meldung vom 02.11.2026, Dashboard › Integrationen › Meetings. Branch `fix/memory-paused-status`.

## Ursache

Die Zeile entsteht an vier Stellen, alle mit derselben Bedingung `MemoryPrivacy.records(.meetings, at:)`
(nicht pausiert **und** der Schalter „Meetings und Kalender“ an):

- `JamieConnect.connect()` und `MeetingSourceConnect.connect()` prüfen sie vor „Jetzt abgleichen“/„Verbinden“;
- der Sidecar prüft dasselbe in `privacy.json` (`meeting_sources.why_not` → Status `paused`), und die App macht
  daraus dieselbe Zeile (`handle(_:)` in beiden Klassen).

Was ich ausgeschlossen habe:

- **Falscher Default:** `MemoryPrivacy()` ist nicht pausiert, alle Quellen außer den Opt-in-Quellen sind an. Der
  Python-Default (`privacy.Privacy()`, fehlende Datei) ist dasselbe.
- **Umgekehrte Bedingung:** Alle `guard`s und `why_not` haben die richtige Richtung.
- **Falscher Schlüssel/Pfad:** `sidecarJSON` schreibt `paused`, `paused_until`, `off`, `on`; `privacy.load` liest
  genau diese Schlüssel. Die App schreibt `privacy.json` beim Start und bei jeder Änderung (auch wenn eine
  zeitlich begrenzte Pause abläuft), in denselben Pfad, den `STARNOTCH_PRIVACY` an den Sidecar übergibt.

Was übrig bleibt, ist **veralteter Zustand**: Die Ablehnung wird als `.failed(pausedLine)` in der Phase der Quelle
gespeichert. Sobald die Pause endet (abgelaufen, fortgesetzt) oder Meetings wieder an sind, setzt nichts diese
Phase zurück. Die Zeile in `MeetingSourceRow.status` zeigt die Phase **vor** „61 Meetings · abgeglichen …“, deshalb
bleibt „pausiert“ stehen, während „Letzter Abgleich 8:03“ (der letzte *erfolgreiche* Abgleich, `lastSynced` wird
bei einem Fehler nicht gelöscht) und die Meeting-Zahl normal aussehen. Dazu kommt: `set(.failed …)` zählt die
Ablehnung im `JamieSyncSchedule` als fehlgeschlagenen Abgleich. Der nächste automatische Abgleich, der die Zeile
überschreiben würde, wartet deshalb 5, 15 oder 60 Minuten, auch wenn die Pause längst vorbei ist.

Wichtig: Eine Pause, die das Rechtsklick-Menü der Insel auslöst („Für 1 Stunde“ ist der erste Eintrag), läuft still
ab. Wer so eine Pause nicht bewusst wahrgenommen hat, sieht danach nur noch die veraltete Zeile.

## Fix

- `JamieSyncSchedule.released()` (NotchCore): Die Ablehnung, die als Fehlschlag gezählt wurde, wird wieder abgezogen.
  Fehlschläge davor bleiben mit ihrem Backoff.
- `JamieConnect.privacyChanged()` und `MeetingSourceConnect.privacyChanged()` (über `MeetingSources.privacyChanged()`):
  Ist die Phase die Pausen-Zeile und lässt Tara Meetings jetzt wieder zu, wird die Phase `.idle` und der Backoff
  gelöscht. Andere Fehler bleiben stehen.
- `AppDelegate.privacyChanged(from:)` ruft das in dem Zweig auf, der schon „Meetings wieder an“ erkennt (Pause
  abgelaufen, fortgesetzt, Schalter wieder an). Dort wird auch schon der Kalender-Snapshot neu geschrieben.
- `MeetingModule.jamieChanged(.idle)` nimmt auch die letzte Jamie-Fehlerzeile aus der Meeting-Zeile in der Notch,
  damit dort nicht dieselbe veraltete Meldung stehen bleibt.

Der Sidecar ist unverändert.

## Wie geprüft

- Neue Tests in `Tests/NotchCoreTests/JamieSyncScheduleTests.swift`:
  `aSyncHeldBackByTarasSwitchesNoLongerWaitsOnceTheyLetMeetingsIn` und `releasingAHoldKeepsTheFailuresBeforeIt`.
  **Nicht ausgeführt:** Hier (Linux) gibt es keine Swift-Toolchain (download.swift.org ist vom Proxy gesperrt), und
  NotchCore importiert AppKit/CoreGraphics, baut also ohnehin nicht unter Linux. Die erwarteten Zeiten habe ich von
  Hand gegen `nextSync`/`shouldSync` nachgerechnet.
- Python-Tests im Sidecar (`agent/`), unverändert: `test_privacy.py`, `test_meeting_sources.py` und
  `test_jamie_sync.py` laufen grün (66 passed). Sie bestätigen, dass `paused`/`off` dort wie beschrieben entstehen.
- Der Swift-Code in NotchKit ist nicht kompiliert.

## Auf dem Mac prüfen

1. `swift build` und `swift test --filter JamieSyncScheduleTests`.
2. Nachstellen: Jamie, Granola und Wispr Flow verbinden. Per Rechtsklick auf die Insel „Für 1 Stunde“ pausieren.
   In Integrationen › Meetings bei jeder Quelle „Jetzt abgleichen“ drücken; jetzt steht die Pausen-Zeile da.
   Dann fortsetzen (Rechtsklick › „Taras Gedächtnis fortsetzen“). Die Zeilen müssen sofort wieder
   „… Meetings · abgeglichen …“ zeigen, und der nächste automatische Abgleich darf nicht 5 Minuten Backoff abwarten.
   Dasselbe mit dem Schalter „Meetings und Kalender“ aus und wieder an, und mit einer Pause, die von selbst abläuft.
3. Beim Tester, falls die Zeile nach dem Fix **ohne** Pause wiederkommt: Dann lehnt der Sidecar wirklich ab.
   Prüfen: `cat ~/Library/Application\ Support/Starnotch/privacy.json` (`"paused": true` oder `"meetings"` in `off`?),
   ob dort `paused_until` steht, und ob noch eine zweite Starnotch-Instanz bzw. ein anderer Build läuft. Die
   Einstellungen liegen in den UserDefaults der Bundle-ID, `privacy.json` aber im Support-Ordner; zwei Builds, die
   denselben Ordner teilen, überschreiben sich die Datei gegenseitig. Diesen Fall konnte ich hier nicht ausschließen.
