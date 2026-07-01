<div align="center">

<img src="docs/assets/eclam-icon.png" width="120" alt="Electronic Clam" />

# Electronic Clam

**Agents must keep working — your Mac shouldn't cook trying.**
Detecta el *trabajo*, no solo un proceso en ejecución.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Swift-AppKit%20%2B%20IOKit-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.6.3-yellow)](CHANGELOG.md)

<!-- i18n-langbar -->
[English](README.md) · [한국어](README.ko.md) · [中文](README.zh-CN.md) · [日本語](README.ja.md) · **Español**

![Demostración del menú de Electronic Clam](docs/assets/eclam-menu-demo.gif)

</div>

---

## Lo más destacado

- **Despierto con la tapa cerrada.** Un interruptor evita que tu Mac duerma incluso con la tapa cerrada — sin comandos de terminal ni contraseña en cada cambio.
- **Detecta el trabajo, no los procesos.** Permanece despierto solo mientras un agente de programación *produce salida de verdad*; cuando el agente se detiene, tu Mac puede volver a dormir.
- **5 agentes listos para usar** — Claude Code, Codex, Cursor, opencode, Antigravity — y puedes añadir los que quieras.
- **Protecciones que se adaptan.** Duerme automáticamente cuando la batería o la temperatura cruzan un límite peligroso.
- **Consciente de la actividad remota.** No duerme mientras lo usas por SSH, compartir pantalla o Tailscale — y mantiene vivas las compilaciones remotas.
- **Nunca lee tus conversaciones ni tu código.** La detección de agentes solo mira las marcas de tiempo del transcript, nunca su contenido.

---

## Funciones

El objetivo es que tu agente siga trabajando — de forma **segura** — sin interrupciones. Todo lo de abajo está al servicio de eso.

### Mantener despierto según el agente

![Demostración de la detección de agentes](docs/assets/eclam-demo-agents.gif)

Es simple: deja que tu agente siga trabajando sin interrupciones.

Por eso el interruptor sigue si el agente *está trabajando ahora mismo*, no si existe un proceso. Mientras trabaja, el Mac permanece despierto; cuando se detiene, se libera (modo **Strict**). También hay un modo **Lax** que simplemente mantiene despierto mientras el proceso esté vivo.

**Detectados por defecto (5):** Claude Code · Codex · Cursor · opencode · Antigravity.

**Activar en Customize (desactivado por defecto):** Aider · Cline · Roo Code · OpenHands · Hermes · Openclaw.

También puedes añadir agentes que no estén aquí — da un patrón glob o deja un único archivo de declaración en `~/.config/eclam/traces.d/*.json`.

Por defecto, los agentes se detectan sondeando sus registros de sesión (~5 s, ~30 s con la pantalla bloqueada), así que un agente recién iniciado puede tardar unos segundos en aparecer. Claude, Codex y Hermes se detectan al instante si instalas sus hooks (opcionales).

### Protecciones de seguridad

![Demostración de las protecciones](docs/assets/eclam-demo-safety.gif)

Ejecutar una carga pesada en modo clamshell dentro de una mochila es un riesgo térmico. Electronic Clam vigila la temperatura y la batería, y deja dormir el Mac cuando la cosa se pone peligrosa:

- **Batería** — el umbral depende de tu configuración: 30 % con la tapa cerrada y sin pantalla externa, 10 % en los demás casos (ajustable). Una conexión de corriente débil o inestable cuenta como batería.
- **Térmico** — combina la señal de macOS con otra interna más sensible para reaccionar antes.
- **Duración máxima** — el modo Desktop (corriente + tapa abierta + pantalla externa) se salta el tope por completo.
- **Modo de Bajo Consumo** — aprieta ambos un paso (+10 puntos de batería, un nivel térmico).

Con la corriente desconectada y la tapa cerrada en una mochila, juzga con más cautela y se libera solo cuando todo vuelve a ser seguro. Puedes optar por recibir una notificación cuando ponga el Mac a dormir.

### Detección de actividad remota

![Demostración de la consciencia remota](docs/assets/eclam-demo-remote.gif)

Electronic Clam no duerme mientras usas el Mac en remoto. Detecta SSH, compartir pantalla, Tailscale y apps de control remoto conocidas. Por defecto es simple: permanece despierto mientras estés conectado.

### Notificaciones de Telegram (desactivadas por defecto)

Conecta tu propio bot de Telegram y recibirás un aviso cuando un agente se detenga o tu Mac se duerma — con el % de batería, la temperatura y el nombre del host.

### Otros

- **CLI + sesiones con nombre** — manéjalo directamente desde la terminal (ver [Usage](#usage)).
- **Hooks de agente opcionales** — al instalarlos se inyecta un hook de señal de actividad en la configuración de Claude / Codex / Hermes; al desinstalarlos se restauran.
- **Restauración del sueño garantizada al salir** — tres capas: restauración síncrona al salir, un manejador de SIGTERM y un watchdog de 20 segundos por si la app se cuelga.
- **Protección de la VPN frente al bloqueo en clamshell (opcional).** Sin pantalla externa y con batería, cerrar la tapa normalmente *bloquea* la pantalla — lo que tira una VPN SSL de FortiClient (necesita volver a iniciar sesión por SAML para reconectar). Una pantalla virtual invisible ancla la sesión, así que la pantalla no se bloquea y el túnel sobrevive. La acción **Apagar pantalla** también se divide en **Dim** (oscura pero segura para la VPN, por defecto) y **Sleep**, con una notificación opcional de desconexión de la VPN.
- **Registro del helper resiliente** — no registra el helper en segundo plano desde una descarga en cuarentena ni desde una ubicación temporal (translocated), donde macOS lo bloquea; en su lugar te guía para mover la app a Applications. Ajustes → General señala copias duplicadas y discrepancias de versión, y `eclam repair` / **Reinstall Helper** recuperan un registro atascado.

## Instalación

```bash
brew install --cask jadhvank/tap/eclam
open /Applications/ElectronicClam.app
```

Activa **Electronic Clam Helper** en **System Settings → General → Login Items & Extensions**.

## Usage

**Haz clic izquierdo** en el icono de la barra de menús para alternar el modo despierto. **Haz clic derecho** para abrir el menú completo.

El icono es una almeja con tres estados: concha en contorno (durmiendo), concha rellena + rayo (lo mantienes despierto tú) y concha rellena + marca remota (un agente, una sesión remota o una protección lo mantiene despierto automáticamente).

### Menú

| Elemento | Acción |
|---|---|
| Encabezado de estado | El estado actual de un vistazo (p. ej. «Dormir al estar inactivo», «Despierto — hasta que salga», «Despierto — sesión remota») |
| **Mantener el Mac despierto** (⌘K) | Alternar el modo despierto |
| **Vigilar agentes** ▸ | Activar/desactivar los agentes a detectar (muestra « • activo» cuando lo está); **Personalizar…** al final |
| **Apagar pantalla — seguir trabajando** | Apaga las pantallas pero mantiene el Mac y los agentes en marcha |
| **Ajustes…** (⌘,) | Abrir ajustes |
| **Salir** (⌘Q) | Salir (restaura el sueño antes) |

### CLI

El cask de Homebrew crea un enlace simbólico `$HOMEBREW_PREFIX/bin/eclam`.

```
eclam on [--for <dur>] [--forever]   # keep awake; default 2h, then the helper auto-releases (no GUI needed, survives reboot)
eclam off
eclam status [--json]                 # also flags a quarantined/outside-Applications app, a failed helper, and duplicate copies
eclam repair                          # recover a wedged/unreachable helper (relaunches the app; guides you to sfltool resetbtm as a last resort)
eclam keep --while <pid>
eclam watch <agent> [--grace s] [--check-interval s] [--max min] [--json]
eclam session start <name> [--message <text>] / stop <name> / list [--json]
eclam debug [agents] [--json]
eclam help
```

**Códigos de salida:** `0` éxito · `1` argumentos incorrectos · `2` helper inalcanzable · `3` se requiere aprobación · `4` cancelado por el usuario.

## Seguridad y privacidad

- Lee los relojes de los archivos, no su contenido.
- Sin telemetría, sin seguimiento, sin analíticas.
- Se exige la verificación del llamante XPC.
- Firmado con Developer ID + notarizado por Apple.
- Los tokens se quedan en local.
- El sueño siempre se restaura al salir o al fallar.
- Una sola vía de permisos (`SMAppService`).

Consulta [Seguridad y privacidad](docs/security.md) para más detalles.

## Advertencias / Limitaciones conocidas

- **La detección puede tardar unos segundos sin un hook.** Los agentes sin un hook instalado se detectan sondeando sus registros de sesión (~5 s, ~30 s con la pantalla bloqueada). Claude / Codex / Hermes son instantáneos en cuanto instalas sus hooks.
- **Sin protecciones de seguridad usando solo la CLI.**
- **Ejecútalo desde Applications.** Si lo abres desde Downloads o una copia aún en cuarentena, macOS no dejará que arranque el helper en segundo plano — mueve Electronic Clam a la carpeta Applications y vuelve a abrirlo.
- **Agentes integrados en VS Code** (Cline / Roo Code) no tienen un proceso independiente, así que la detección en modo Lax es limitada.
- **Solo Apple Silicon**, macOS 13+ (Ventura).

## Tecnologías

- **Lenguaje / UI:** Swift + AppKit (`NSStatusItem`, app de barra de menús `LSUIElement` — sin Dock).
- **Control de energía:** IOKit SPI — `IOPMSetSystemPowerSetting("SleepDisabled")` mediante un binding `@_silgen_name`.
- **Separación de privilegios:** un daemon `SMAppService` que habla con la app por `NSXPCConnection` (mach service).
- **Compilación:** `swiftc` directo (sin SwiftPM), **sin dependencias externas**.
- **Objetivos:** arm64, macOS 13+ (Ventura).

## Build from source

```bash
./scripts/build.sh            # app + helper + hook binaries (Developer ID signed)
open build/ElectronicClam.app
```

- Invocación directa de `swiftc`, objetivo `arm64-apple-macos13.0`. Usa `ECLAM_SIGN_ID=-` para compilaciones locales ad-hoc rápidas.
- Estructura del bundle: `Contents/MacOS/{ElectronicClam, ElectronicClamHelper, eclam-hook}` + `Contents/Library/LaunchDaemons/com.jadhvank.eclam.helper.plist`.
- Las compilaciones de lanzamiento se firman con Developer ID y se notarizan (con staple por `release.sh`).

## Historial de versiones

Lanzamientos recientes — historial completo en [CHANGELOG.md](CHANGELOG.md):

- **0.6.3** — Corrección: con la protección de bloqueo en clamshell activada, conectar una pantalla externa real ya no altera tu disposición guardada de «interna + externa». El ancla invisible ahora se aparta de inmediato (sin volver a espejar) en cuanto aparece una pantalla real, dejando que macOS restaure la disposición que guardaste; vuelve automáticamente cuando quitas la externa. La protección de bloqueo en clamshell sin pantalla no cambia.
- **0.6.2** — Protección de la VPN frente al bloqueo en clamshell (opcional): sin pantalla externa y con batería, cerrar la tapa ya no bloquea la pantalla, así que una VPN SSL de FortiClient sobrevive en vez de caerse — una pantalla virtual invisible ancla la sesión. La acción **Apagar pantalla** ahora te deja elegir **Dim** (segura para la VPN, por defecto) o **Sleep**, con una notificación opcional de desconexión de la VPN.
- **0.6.1** — Estado honesto del helper: un helper muerto pero registrado ya no aparece como falso «activado». `eclam status` lo informa como `unreachable` (código de salida 2), la app se autorrepara al reiniciarse, un nuevo comando `eclam repair` y un aviso en la barra de menús lo muestran, y `eclam status` ahora también informa del estado de inicio al arrancar sesión.
- **0.6.0** — Inicio al arrancar sesión, notificaciones de actualización en la app, historial de actividad, internacionalización (English · 한국어 · 中文 · 日本語 · Español), interruptor de un clic, temas de icono en la barra de menús, política de inactividad remota, notificaciones de estado por Telegram, firma con Developer ID + notarización.

Anteriormente: detección de agentes y los comandos `watch` / `session` (0.5.x), protecciones de batería / temperatura / temporizador según el estado (0.4.x), detección de actividad remota y la primera CLI (0.3.x).

## Apóyanos

Electronic Clam es gratis y de código abierto. Él mantiene despierto a tu agente; tu café mantiene despierto al desarrollador. ☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E2%98%95-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/jadhvank)

## Licencia

[MIT](LICENSE).

---

<sub>`README.zh-CN.md`, `README.ja.md` y `README.es.md` se generan a partir de este archivo con el comando `/translate` — no los edites a mano. `README.ko.md` se mantiene a mano.</sub>
