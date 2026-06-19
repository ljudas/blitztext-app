# Spec: Umschaltbarer API-Provider (OpenAI / Scaleway / Eigener)

## Context

Die App (`BlitztextMac`, macOS Menubar) ruft Transkription und Text-Rewrite **hart auf OpenAI** auf — Endpoint, Modellnamen und der einzige Keychain-Key sind im Code fest verdrahtet (`TranscriptionService.swift:32-33`, `LLMService.swift:24-26,60`, `KeychainService.swift:4`). Das öffentliche Repo (`cmagnussen/blitztext-app`, nur 3 Commits, Stand 2026-06-02) enthält **kein** Provider-/Endpoint-Feature; die im Video gezeigte Proxy-Anbindung liegt nur in der internen Firmen-Version.

Ziel: Der Nutzer will sein eigenes Modell (zunächst **Whisper-large-v3 auf Scaleway**) nutzen und später beliebige OpenAI-kompatible Endpoints eintragen können. Scaleways Audio- und Chat-APIs sind OpenAI-kompatibel (`https://api.scaleway.ai/v1/audio/transcriptions`, `.../chat/completions`), daher genügt eine Parametrisierung von URL + Modell + Key — kein neuer Request-Pfad.

Mit dem Nutzer abgestimmtes Verhalten:
- **Drei Provider parallel** persistiert, **immer genau einer aktiv**, gilt für Transkription *und* Rewrite gleichzeitig (nie funktionsgetrennt).
- **Pro Provider ein eigener Key** im Keychain → beim Umschalten kein Neueintippen.
- **Chat-Modell umschaltbar** (Scaleway/Eigener); Transkriptions-Modell pro Provider fix.
- OpenAI-Verhalten bleibt **unverändert** (Default, Zwei-Stufen-Chat-Modelle).

## Scope

| | OpenAI (Default) | Scaleway | Eigener |
|---|---|---|---|
| Base-URL | fest `https://api.openai.com/v1` | fest `https://api.scaleway.ai/v1` | frei eintragbar |
| Transkriptions-Modell | fest `whisper-1` | fest `whisper-large-v3` | frei eintragbar |
| Chat-Modell | fest 2 Stufen (`gpt-4o-mini`/`gpt-4o`) | **1 wählbares** Modell | **1** frei eintragbar |
| Key | `apiKey.openai` (= bestehender Slot) | `apiKey.scaleway` | `apiKey.custom` |

Out of Scope: funktionsgetrennte Provider, unbegrenzte Provider-Liste, LiteLLM-Proxy (geht später automatisch über „Eigener" + Proxy-URL), lokaler Modus (`LocalTranscriptionService`) bleibt unberührt.

## Design

### 1. Provider-Modell (neu)

Neues `enum APIProvider: String, Codable, CaseIterable { case openai, scaleway, custom }` mit `displayName`.

Neuer Wertetyp `ProviderConfig` (resolved, immutable), den die Services bekommen:
```
struct ProviderConfig {
    let transcriptionsURL: URL      // <base>/audio/transcriptions
    let chatCompletionsURL: URL     // <base>/chat/completions
    let transcriptionModel: String
    let chatModelLight: String      // openai: gpt-4o-mini; sonst = gewähltes Modell
    let chatModelHeavy: String      // openai: gpt-4o;      sonst = gewähltes Modell
    let apiKey: String?             // aus Keychain für aktiven Provider
}
```
Auflösung als Funktion auf den Settings (siehe 3): baut Base-URL je Provider, hängt `/audio/transcriptions` bzw. `/chat/completions` an, lädt den passenden Key.

### 2. Keychain — Key pro Provider

`KeychainService.swift`: `KeychainKey` erweitern um `case scalewayAPIKey`, `case customAPIKey` (bestehender `openAIAPIKey` bleibt → **abwärtskompatibel**, vorhandene OpenAI-Keys gelten weiter). Mapping-Helper `KeychainKey(for: APIProvider)`.

`KeychainService.isConfigured` (prüft heute nur `openAIAPIKey`) wird **provider-abhängig**: neue Methode `hasKey(for: APIProvider) -> Bool`. Die bisherige `isConfigured`-Nutzung in `AppState` (`AppState.swift:62`, `:228`) auf aktiven Provider umstellen.

### 3. Settings-Persistenz

Neuer Codable-Struct in `WorkflowProtocol.swift` (gleiches Muster wie `AppSettings`, mit `decodeIfPresent`-Defaults für Migration):
```
struct ProviderSettings: Codable {
    var activeProvider: APIProvider = .openai
    var scalewayChatModel: String = ""     // Platzhalter-Vorschlag in UI
    var customBaseURL: String = ""         // OpenAI-kompatible Root, z.B. https://host/v1
    var customTranscriptionModel: String = ""
    var customChatModel: String = ""
}
```
In `AppState` als neue `var providerSettings: ProviderSettings { didSet { saveSettings() } }` aufnehmen (Muster der 5 bestehenden Settings, `AppState.swift:38-56`) und in `SettingsContainer` (`AppState.swift:600-606`) + `saveSettings`/`load*` ergänzen.

Resolver `providerSettings.resolvedConfig(apiKey:)` → `ProviderConfig`. Base-URLs: openai/scaleway konstant, custom aus `customBaseURL` (getrimmt, ohne Trailing-Slash). Chat-Modelle: openai fix zweistufig; scaleway = `scalewayChatModel`; custom = `customChatModel` (beide Stufen identisch).

### 4. Services parametrisieren

**`TranscriptionService.transcribe(...)`**: Parameter `config: ProviderConfig` ergänzen. Konstanten `remoteModel`/`transcriptionsURL` (`:32-33`) entfallen; stattdessen `config.transcriptionModel` + `config.transcriptionsURL` + `config.apiKey`. Multipart-Body bleibt identisch (OpenAI-kompatibel). `notConfigured`-Fehler weiterhin bei fehlendem Key. Das optionale `prompt`-Feld (Custom-Terms) bleibt — bei Scaleway unkritisch, da nur gesendet wenn Terms gesetzt.

**`LLMService`**: `RewriteModel` (`:23-26`) wird zur reinen **Stufen-Kennung** (`.fastEdit`/`.rageMode`) ohne fixen String. `complete(...)` bekommt `config: ProviderConfig`; Modellname via `tier == .fastEdit ? config.chatModelLight : config.chatModelHeavy`. URL/Key aus `config`. Öffentliche Methoden `improve/dampfAblassen/addEmojis` um `config:` erweitern.

Fehlertexte „OpenAI…" in `TranscriptionError`/`LLMError` neutralisieren (z. B. „API-Key fehlt", „Anbieter-Fehler"), da nicht mehr immer OpenAI.

### 5. Auflösung am Call-Site (AppState als Owner)

`AppState` baut die Workflows (Factory um `AppState.swift:169`, setzt schon `backend`). Dort `ProviderConfig` einmal auflösen (`providerSettings.resolvedConfig(apiKey: KeychainService.load(key: KeychainKey(for: activeProvider)))`) und wie `customTerms`/`language`/`backend` in die Workflow-`init` durchreichen. Die 4 Workflows (`TranscriptionWorkflow`, `TextImprovementWorkflow`, `DampfAblassenWorkflow`, `EmojiTextWorkflow`) halten den `config`-Wert und übergeben ihn an die Service-Aufrufe (Transkription + LLM).

### 5a. Umschalt-Verhalten (kein Pro-Aktion-Prompt)

- Provider-Wahl passiert **ausschließlich einmalig im Settings-Picker**. Diktat und alle Rewrite-Workflows nutzen still `providerSettings.activeProvider` — **kein Auswahl-Dialog pro Hotkey/Aktion**.
- Der Picker zeigt **immer alle drei** festen Einträge (OpenAI/Scaleway/Eigener), unabhängig davon, wie viele schon einen Key haben. „Konfiguriert" = Key (und bei Eigener Base-URL + Modell) hinterlegt; die Auswahl-Liste ändert sich dadurch nicht.
- **Kein Auto-Fallback**: Ist der aktive Provider ohne gültigen Key, wechselt die App nicht heimlich zu einem anderen — der Workflow meldet einmalig „API-Key fehlt" (nur ein Hinweis, kein Auswahl-Prompt). Aktiver Provider wird ausschließlich über den Picker gesteuert.
- Umschalten lädt nur die gespeicherten Werte des Zielproviders; die Daten der anderen Provider bleiben unangetastet.

### 6. Settings-UI (`SettingsContentView.swift`, `AccessSettingsView`)

- **Picker „Anbieter"** gebunden an `appState.providerSettings.activeProvider`.
- **Key-Feld**: Label dynamisch („API-Key (\<Anbieter>)"); Laden/Speichern gegen `KeychainKey(for: activeProvider)` statt fix `.openAIAPIKey` (`:386` generalisieren). `@State openAIAPIKey` (`:69`) bei Provider-Wechsel neu aus Keychain laden. Masked-Display `apiKeyDisplayValue(for:)` (`AppState.swift:350-358`) mit aktivem Key aufrufen.
- **Validierung**: `sk-`-Regex (`:59`) nur für OpenAI; für scaleway/custom Non-Empty-Check (Scaleway-Keys sind kein `sk-`).
- **Bedingte Felder**: bei Scaleway ein „Chat-Modell"-Feld (Platzhalter-Beispiel); bei Eigener zusätzlich „Base-URL" + „Transkriptions-Modell" + „Chat-Modell". Gebunden an `appState.providerSettings.*`.
- Hinweis: leeres Chat-Modell (scaleway/custom) → Rewrite-Workflows zeigen klaren Fehler; **Transkription funktioniert unabhängig davon**.

## Dateien

| Datei | Änderung |
|---|---|
| `BlitztextMac/Services/KeychainService.swift` | `KeychainKey` um 2 Cases, `KeychainKey(for:)`, `hasKey(for:)` |
| `BlitztextMac/Features/Workflows/WorkflowProtocol.swift` | `APIProvider`, `ProviderSettings`, `ProviderConfig`, `resolvedConfig` |
| `BlitztextMac/Services/TranscriptionService.swift` | `config:`-Param, Konstanten entfernen, Fehlertexte neutral |
| `BlitztextMac/Services/LLMService.swift` | `config:`-Param, `RewriteModel` → Stufe, Fehlertexte neutral |
| `BlitztextMac/App/AppState.swift` | `providerSettings` + Persistenz + Config-Auflösung in Workflow-Factory; `isConfigured` provider-abhängig |
| `BlitztextMac/Features/Workflows/*Workflow.swift` (4×) | `config`-Param in `init` + an Service-Aufrufe |
| `BlitztextMac/Features/Settings/SettingsContentView.swift` | Anbieter-Picker, dynamisches Key-Feld, bedingte Modell/URL-Felder, Validierung |

## Abwärtskompatibilität / Migration

- Bestehende `openAIAPIKey`-Keychain-Einträge bleiben gültig (Default-Provider = openai).
- `ProviderSettings` fehlt in alten JSON-Settings → `decodeIfPresent`-Defaults (activeProvider = openai) ⇒ unveränderter Status quo für Bestandsnutzer.
- Kein Datenverlust, keine Pflicht-Neukonfiguration.

## Verifikation

1. **Build**: `cd /Users/larsjudas/Development/blitztext-app && ./build.sh --debug` (XcodeGen + xcodebuild) muss fehlerfrei sein.
2. **Default unverändert**: App starten, ohne Settings-Änderung OpenAI-Key eintragen → Diktat + Rewrite wie bisher (Regression-Check OpenAI-Pfad).
3. **Scaleway-Transkription (Kernziel)**: Anbieter = Scaleway, Scaleway-Secret-Key eintragen, diktieren → Text kommt von `api.scaleway.ai` (per Charles/Proxy oder Netzwerk-Log gegenprüfen, dass `whisper-large-v3` an Scaleway geht). Achtung: Scaleway-Audio ist Beta.
4. **Scaleway-Rewrite**: gültiges Chat-Modell eintragen → Blitztext+ liefert Ergebnis; leeres Chat-Modell → klare Fehlermeldung, Transkription läuft trotzdem.
5. **Eigener**: Base-URL auf lokalen OpenAI-kompatiblen Endpoint (z. B. LiteLLM `http://localhost:4000/v1`) + Modell + Key → Transkription/Chat gehen dorthin.
6. **Persistenz/Umschalten**: Provider wechseln, App neu starten → Auswahl, Modelle und je Key bleiben erhalten; Keys werden nicht vermischt.

Tests: Das Repo hat aktuell keine Test-Suite (ROADMAP nennt sie erst als „Next Useful Work"); Verifikation daher manuell wie oben. Optional kleiner Unit-Test für `resolvedConfig` (URL-Komposition je Provider), falls eine Testtarget-Einrichtung gewünscht ist — sonst weggelassen (YAGNI).
