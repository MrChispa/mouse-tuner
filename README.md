# Mouse Tuner

**Ajusta la velocidad y la precisión de tu mouse o trackball, por dispositivo, desde la barra de Omarchy.**
**Tune your mouse or trackball speed and precision, per device, right from the Omarchy bar.**

[![Omarchy plugin](https://img.shields.io/badge/Omarchy-plugin-4C8BF5)](#)
[![Hyprland](https://img.shields.io/badge/Hyprland-0.5x-58E1FF)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-orange)](#)

<a name="es"></a>
🇪🇸 [Español](#es) · 🇬🇧 [English](#en)

---

<a name="es"></a>

# 🇪🇸 Español

## Qué es

Mouse Tuner es un **plugin de barra para Omarchy** que ajusta la **velocidad** y la **precisión** del puntero **por dispositivo**, sin tocar el resto. Está pensado para trackballs y mice de precisión que se sienten "demasiado rápidos e imprecisos".

Eliges un dispositivo, eliges un preset o arrastras el slider, y el cambio se aplica en vivo y sobrevive a los reinicios. **Tu touchpad nunca se modifica**, porque cada ajuste está acotado al dispositivo seleccionado.

---

## El problema (por qué existe)

La velocidad final del cursor es el resultado de dos capas:

```
velocidad = DPI del sensor (hardware)  ×  aceleración + sensibilidad (software)
```

Hyprland, por defecto, usa `accel_profile = adaptive`: **aceleración**. Eso significa que la misma cantidad de movimiento físico mueve el cursor distancias distintas según qué tan rápido muevas. En un mouse de escritorio grande suele ir bien; en un **trackball** es terrible, porque rompe la memoria muscular y da una sensación constante de imprecisión.

La solución clásica es:

- `accel_profile = flat` → movimiento **1:1**, predecible.
- `sensitivity` más baja → menos velocidad, más control.

Hyprland expone ambas como ajustes **por dispositivo**:

```lua
hl.device({ name = "logitech-usb-receiver-mouse", accel_profile = "flat", sensitivity = -0.30 })
```

Mouse Tuner escribe exactamente eso, para el dispositivo que elijas, desde la barra.

---

## Características

- 🎯 **Perfil de aceleración** por dispositivo: `flat` (precisión) o `adaptive` (por defecto).
- 🐢 **Sensibilidad** de `-1.00` a `1.00` con slider y aplicación en vivo (~250 ms tras soltar).
- 💾 **Persistente**: se guarda en tu config de Hyprland, no solo en memoria.
- 🖱️ **Por dispositivo**: solo cambia el puntero que eliges; el resto queda intacto.
- 🖐️ **Trackpads soportados**: sección propia para trackpads (Magic Trackpad 2 incluido) con natural scrolling, clickfinger, disable-while-typing y velocidad de scroll.
- ⚡ **Motor CLI independiente** (`bin/mouse-tuner.sh`), usable sin la barra.
- 🔒 **Escritura atómica con lock**: nada fuera de su bloque se toca, byte a byte.
- 🛟 **A prueba de errores**: si Hyprland rechaza la config, se restaura el archivo anterior y el cambio falla en vez de quedar a medias.
- 🧩 Sin dependencias de Python; solo Bash + `hyprctl`.

---

## Requisitos

- **Omarchy** (o cualquier Hyprland) con el shell de Omarchy.
- `hyprctl` disponible (viene con Hyprland).
- La fuente de la barra (JetBrainsMono Nerd Font, incluida en Omarchy) para el icono.

---

## Instalación

**Desde git (recomendado):**

```bash
omarchy plugin add https://github.com/MrChispa/mouse-tuner.git --enable
```

**Desde un checkout local:**

```bash
git clone https://github.com/MrChispa/mouse-tuner.git
cd mouse-tuner
./install.sh
```

`install.sh` valida el plugin, lo copia a `~/.config/omarchy/plugins/io.github.mrchispa.mouse-tuner` y lo habilita en la sección derecha de la barra.

Si el icono no aparece de inmediato:

```bash
omarchy-shell shell rescanPlugins
```

> **Nota:** si editas el código del plugin, `rescanPlugins` puede no recargar un widget ya instanciado. En ese caso usa `omarchy restart shell`.

---

## Uso

1. **Clic** en el icono del mouse en la barra (tooltip: *Mouse Tuner*).
2. Elige el **dispositivo** que quieres ajustar. Los touchpad se marcan como *(touchpad)*.
3. Elige un **preset**:

   | Preset       | Perfil     | Sensibilidad | Para qué                         |
   | ------------ | ---------- | ------------ | -------------------------------- |
   | **Precise**  | `flat`     | `-0.35`      | Trackballs y apuntado fino       |
   | **Balanced** | `flat`     | `-0.15`      | Punto medio                      |
   | **Default**  | `adaptive` | `0.00`       | Comportamiento original de libinput |

4. O arrastra el **slider** de sensibilidad (`-1.00` a `1.00`). Se aplica solo.
5. Si el dispositivo es un **trackpad**, aparece además la sección **TRACKPAD** (ver más abajo).
6. **Reset device** elimina el ajuste y devuelve ese dispositivo al default del sistema.

El panel muestra el estado activo, por ejemplo `flat · -0.30` en un mouse o `natural off · clickfinger on · scroll ×0.80` en un trackpad.

---

## Línea de comandos

El motor es un script independiente, útil para scripts o para otra máquina:

```bash
bin/mouse-tuner.sh devices                                              # lista dispositivos (JSON)
bin/mouse-tuner.sh status                                               # ajustes activos (JSON)
bin/mouse-tuner.sh set --device <name> --profile flat --sensitivity -0.3
bin/mouse-tuner.sh remove --device <name>                               # quita un dispositivo
bin/mouse-tuner.sh reset                                                # quita todo el bloque gestionado
```

`set` es un **upsert**: solo escribe los campos que le pasas y conserva los demás. Si un campo no estaba puesto, no se añade. Campos disponibles:

| Flag | Campo en `hl.device` | Valor |
| ---- | -------------------- | ----- |
| `--profile` | `accel_profile` | `flat`, `adaptive` |
| `--sensitivity` | `sensitivity` | `-1.00` .. `1.00` |
| `--natural-scroll` | `natural_scroll` | `true`, `false` |
| `--clickfinger` | `clickfinger_behavior` | `true`, `false` |
| `--disable-while-typing` | `disable_while_typing` | `true`, `false` |
| `--left-handed` | `left_handed` | `true`, `false` |
| `--middle-button-emulation` | `middle_button_emulation` | `true`, `false` |
| `--scroll-factor` | `scroll_factor` | `0.10` .. `8.00` (se recorta al rango) |
| `--drag-lock` | `drag_lock` | `0`, `1` |
| `--drag-3fg` | `drag_3fg` | `0`, `1`, `2` |
| `--unset <campo>` | — | borra un campo ya guardado (repetible) |

Un campo que no esté en esa lista se rechaza antes de escribir nada. Eso incluye `tap-to-click` y `tap-and-drag`, que Hyprland no acepta por dispositivo.

---

## Cómo funciona

Mouse Tuner es dueño de un único bloque claramente marcado en `~/.config/hypr/input.lua`:

```lua
-- [[ MOUSE_TUNER_START ]]
-- Managed by Mouse Tuner. Edit from the bar widget, not by hand.
hl.device({ name = "logitech-usb-receiver-mouse", accel_profile = "flat", sensitivity = -0.30 })
-- [[ MOUSE_TUNER_END ]]
```

- Cada escritura es **atómica** (archivo temporal + `mv`) y se serializa con un lock, así dos clics rápidos no corrompen el archivo.
- Todo lo que está **fuera** de las marcas se conserva **byte a byte**.
- Después de cada cambio ejecuta `hyprctl reload`, así el ajuste toma efecto al instante y persiste porque ya forma parte de la config.
- Si `hyprctl configerrors` devuelve algo después del reload, se restaura el archivo anterior byte a byte, se recarga otra vez y el comando falla con el error de Hyprland. Nunca queda una config rota.
- Los datos de dispositivos se leen de `hyprctl devices -j`.

---

## Trackpads y Magic Trackpad 2

Hyprland trata los trackpads como touchpads libinput. El Apple Magic Trackpad 2 (por Bluetooth o USB) aparece como `apple-inc.-magic-trackpad`, y Mouse Tuner lo detecta por el nombre (`touchpad` o `trackpad`, sin distinguir mayúsculas) y muestra la sección **TRACKPAD** cuando lo seleccionas. En la lista de dispositivos se marca con *(touchpad)*.

### Driver

- No hace falta DKMS ni drivers externos: el soporte del Magic Trackpad 2 está **en el kernel**, en `hid_magicmouse` (soporte MT2 desde Linux 4.20).
- El kernel lo publica como un **clickpad libinput** (`PROP=5` = POINTER|BUTTONPAD) y `hyprctl devices` lo lista dentro de `mice[]`.

### Qué se puede ajustar por dispositivo

Estos campos sí se aceptan dentro de `hl.device({...})`:

`accel_profile`, `sensitivity`, `natural_scroll`, `scroll_factor`, `left_handed`, `scroll_method`, `scroll_button`, `clickfinger_behavior`, `disable_while_typing`, `middle_button_emulation`, `tap_button_map`, `drag_lock`, `drag_3fg`.

### tap-to-click es global

`tap-to-click` y `tap-and-drag` **no existen por dispositivo** en Hyprland: solo se configuran en `input:touchpad`, de forma global para todos los touchpads. Por eso el panel lo aclara con una nota y no ofrece un toggle por dispositivo.

### Cómo ajustarlo desde el panel

1. Elige el trackpad en la lista de dispositivos.
2. Usa un preset —**Apple-like** (`natural_scroll` on, clickfinger on, scroll ×0.8) o **Traditional** (`natural_scroll` off, clickfinger on, scroll ×1.0)— o mueve cada control por separado:
   - **Natural scrolling** (`natural_scroll`)
   - **Clickfinger (2-finger right click)** (`clickfinger_behavior`)
   - **Disable while typing** (`disable_while_typing`)
   - **Scroll speed** (`scroll_factor`, de `0.10` a `2.00`, se aplica ~250 ms después de soltar)
3. Cada control escribe **solo sus propios campos**: tocar un toggle no añade `accel_profile` ni `sensitivity` que no hayas pedido. Puedes dejar el trackpad sin perfil de aceleración y sin sensibilidad para que libinput use sus valores por defecto.

Un resultado típico en `~/.config/hypr/input.lua`:

```lua
hl.device({ name = "apple-inc.-magic-trackpad", clickfinger_behavior = true, disable_while_typing = false, natural_scroll = false, scroll_factor = 0.8 })
```

O el mismo ajuste desde la CLI:

```bash
bin/mouse-tuner.sh set --device apple-inc.-magic-trackpad \
  --natural-scroll false --clickfinger true \
  --disable-while-typing false --scroll-factor 0.8
```

### Limitación conocida: Bluetooth y suspensión

Con Bluetooth, después de suspender el equipo el Magic Trackpad 2 puede:

- **no reconectarse solo**, o
- reconectarse pero con **los gestos multitáctiles detenidos** (el kernel no vuelve a inicializar el modo multitáctil).

Si pasa, reconéctalo a mano (apágalo y enciéndelo, o `bluetoothctl connect <MAC>`) o ejecuta un hook al volver de suspensión que fuerce la reconexión. En Omarchy no hay un directorio de hooks para suspensión, así que las dos opciones limpias son:

- un script en `/usr/lib/systemd/system-sleep/` (nivel sistema, requiere `sudo`), o
- un servicio de usuario `systemd` con `After=suspend.target` que ejecute `bluetoothctl connect <MAC>` y `sleep 1`.

Mientras el dispositivo no se re-inicialice, Hyprland puede listarlo sin gestos aunque los ajustes de Mouse Tuner sigan aplicados.

---

## Solución de problemas

| Problema                          | Solución                                                                 |
| --------------------------------- | ------------------------------------------------------------------------ |
| No aparecen dispositivos          | Ejecuta `hyprctl devices` y revisa la sección `mice:`. Enciende el mouse. |
| El ajuste no se aplica            | `hyprctl configerrors` debe estar vacío; luego `hyprctl reload`.          |
| El icono no aparece en la barra   | `omarchy-shell shell rescanPlugins` o `omarchy restart shell`.            |
| Un dispositivo es rechazado       | Su nombre tiene caracteres que el motor no escribe (`/`, comillas, `..`). |
| Un ajuste es rechazado            | Solo se aceptan los campos de la tabla de la CLI; `tap-to-click` es global. |
| El trackpad no se marca *(touchpad)* | Debe aparecer en `mice[]` de `hyprctl devices -j` y su nombre debe contener `touchpad` o `trackpad`. |
| El trackpad no responde tras suspender | Reconéctalo (`bluetoothctl connect <MAC>`); es la limitación de Bluetooth descrita arriba. |

---

## Desinstalación

```bash
omarchy plugin remove io.github.mrchispa.mouse-tuner
```

Antes de desinstalar, usa **Reset device** (o `bin/mouse-tuner.sh reset`) si quieres borrar también el ajuste guardado en `input.lua`.

---

## Licencia

MIT — ver [LICENSE](LICENSE). © MrChispa.

---

<a name="en"></a>

# 🇬🇧 English

## What it is

Mouse Tuner is an **Omarchy bar plugin** that tunes pointer **speed** and **precision** **per device**, without touching anything else. It is built for trackballs and precision mice that feel "too fast and imprecise".

Pick a device, pick a preset or drag the slider, and the change applies live and survives reboots. **Your touchpad is never modified**, because every setting is scoped to the device you selected.

---

## The problem (why it exists)

Final cursor speed is the product of two layers:

```
speed = sensor DPI (hardware)  ×  acceleration + sensitivity (software)
```

Hyprland defaults to `accel_profile = adaptive`: **acceleration**. The same physical movement lands the cursor in different places depending on how fast you move. That is fine for a large desktop mouse and terrible for a **trackball**, where it breaks muscle memory and feels permanently imprecise.

The classic fix:

- `accel_profile = flat` → **1:1**, predictable movement.
- Lower `sensitivity` → less speed, more control.

Hyprland exposes both as **per-device** settings:

```lua
hl.device({ name = "logitech-usb-receiver-mouse", accel_profile = "flat", sensitivity = -0.30 })
```

Mouse Tuner writes exactly that, for the device you choose, from the bar.

---

## Features

- 🎯 **Per-device acceleration profile**: `flat` (precision) or `adaptive` (default).
- 🐢 **Sensitivity** from `-1.00` to `1.00`, with a live slider (applied ~250 ms after you stop).
- 💾 **Persistent**: written into your Hyprland config, not just memory.
- 🖱️ **Per device**: only the pointer you pick changes; everything else stays as it was.
- 🖐️ **Trackpad support**: a dedicated section for trackpads (Magic Trackpad 2 included) with natural scrolling, clickfinger, disable-while-typing and scroll speed.
- ⚡ **Standalone CLI engine** (`bin/mouse-tuner.sh`), usable without the bar.
- 🔒 **Atomic, locked writes**: nothing outside its block is touched, byte for byte.
- 🛟 **Fail-safe**: if Hyprland rejects the config, the previous file is restored and the change fails instead of landing half-applied.
- 🧩 No Python dependency; just Bash + `hyprctl`.

---

## Requirements

- **Omarchy** (or any Hyprland setup) with the Omarchy shell.
- `hyprctl` available (ships with Hyprland).
- The bar font (JetBrainsMono Nerd Font, bundled with Omarchy) for the icon.

---

## Install

**From git (recommended):**

```bash
omarchy plugin add https://github.com/MrChispa/mouse-tuner.git --enable
```

**From a local checkout:**

```bash
git clone https://github.com/MrChispa/mouse-tuner.git
cd mouse-tuner
./install.sh
```

`install.sh` validates the plugin, copies it to `~/.config/omarchy/plugins/io.github.mrchispa.mouse-tuner` and enables it in the right bar section.

If the icon does not show up immediately:

```bash
omarchy-shell shell rescanPlugins
```

> **Note:** if you edit the plugin's code, `rescanPlugins` may not reload an already-instantiated widget. In that case run `omarchy restart shell`.

---

## Usage

1. **Click** the mouse icon in the bar (tooltip: *Mouse Tuner*).
2. Pick the **device** you want to tune. Touchpads are marked *(touchpad)*.
3. Pick a **preset**:

   | Preset       | Profile    | Sensitivity | Best for                        |
   | ------------ | ---------- | ----------- | ------------------------------- |
   | **Precise**  | `flat`     | `-0.35`     | Trackballs and fine aiming      |
   | **Balanced** | `flat`     | `-0.15`     | Middle ground                   |
   | **Default**  | `adaptive` | `0.00`      | libinput's original behaviour   |

4. Or drag the **sensitivity slider** (`-1.00` to `1.00`). It applies on its own.
5. If the device is a **trackpad**, a **TRACKPAD** section appears as well (see below).
6. **Reset device** removes the override and returns that device to the system default.

The panel shows the active state, for example `flat · -0.30` for a mouse or `natural off · clickfinger on · scroll ×0.80` for a trackpad.

---

## Command line

The engine is a standalone script, handy for scripting or another machine:

```bash
bin/mouse-tuner.sh devices                                              # list devices (JSON)
bin/mouse-tuner.sh status                                               # active settings (JSON)
bin/mouse-tuner.sh set --device <name> --profile flat --sensitivity -0.3
bin/mouse-tuner.sh remove --device <name>                               # drop one device
bin/mouse-tuner.sh reset                                                # drop the whole managed block
```

`set` is an **upsert**: it writes only the fields you pass and keeps the rest. A field that was not set before is not added. Available flags:

| Flag | Field in `hl.device` | Value |
| ---- | -------------------- | ----- |
| `--profile` | `accel_profile` | `flat`, `adaptive` |
| `--sensitivity` | `sensitivity` | `-1.00` .. `1.00` |
| `--natural-scroll` | `natural_scroll` | `true`, `false` |
| `--clickfinger` | `clickfinger_behavior` | `true`, `false` |
| `--disable-while-typing` | `disable_while_typing` | `true`, `false` |
| `--left-handed` | `left_handed` | `true`, `false` |
| `--middle-button-emulation` | `middle_button_emulation` | `true`, `false` |
| `--scroll-factor` | `scroll_factor` | `0.10` .. `8.00` (clamped) |
| `--drag-lock` | `drag_lock` | `0`, `1` |
| `--drag-3fg` | `drag_3fg` | `0`, `1`, `2` |
| `--unset <field>` | — | drop an already stored field (repeatable) |

Any field outside that list is rejected before anything is written. That includes `tap-to-click` and `tap-and-drag`, which Hyprland does not accept per device.

---

## How it works

Mouse Tuner owns one clearly marked block in `~/.config/hypr/input.lua`:

```lua
-- [[ MOUSE_TUNER_START ]]
-- Managed by Mouse Tuner. Edit from the bar widget, not by hand.
hl.device({ name = "logitech-usb-receiver-mouse", accel_profile = "flat", sensitivity = -0.30 })
-- [[ MOUSE_TUNER_END ]]
```

- Every write is **atomic** (temp file + `mv`) and serialized with a lock, so two quick clicks cannot corrupt the file.
- Everything **outside** the markers is preserved **byte for byte**.
- After each change it runs `hyprctl reload`, so the setting takes effect immediately and persists because it is now part of the config.
- If `hyprctl configerrors` reports anything after the reload, the previous file is restored byte for byte, Hyprland is reloaded again, and the command fails with Hyprland's error text. A broken config is never left behind.
- Device data comes from `hyprctl devices -j`.

---

## Trackpads and the Magic Trackpad 2

Hyprland treats trackpads as libinput touchpads. The Apple Magic Trackpad 2 (over Bluetooth or USB) shows up as `apple-inc.-magic-trackpad`, and Mouse Tuner detects it by name (`touchpad` or `trackpad`, case-insensitive) and shows the **TRACKPAD** section when you select it. In the device list it is marked *(touchpad)*.

### Driver

- No DKMS or out-of-tree driver is needed: Magic Trackpad 2 support is **in the kernel**, in `hid_magicmouse` (MT2 support since Linux 4.20).
- The kernel exposes it as a **libinput clickpad** (`PROP=5` = POINTER|BUTTONPAD) and `hyprctl devices` lists it under `mice[]`.

### What can be set per device

These fields are accepted inside `hl.device({...})`:

`accel_profile`, `sensitivity`, `natural_scroll`, `scroll_factor`, `left_handed`, `scroll_method`, `scroll_button`, `clickfinger_behavior`, `disable_while_typing`, `middle_button_emulation`, `tap_button_map`, `drag_lock`, `drag_3fg`.

### tap-to-click is global

`tap-to-click` and `tap-and-drag` **do not exist per device** in Hyprland: they are only configured under `input:touchpad`, globally for every touchpad. That is why the panel says so in a hint line instead of offering a per-device toggle.

### How to tune it from the panel

1. Pick the trackpad in the device list.
2. Use a preset —**Apple-like** (`natural_scroll` on, clickfinger on, scroll ×0.8) or **Traditional** (`natural_scroll` off, clickfinger on, scroll ×1.0)— or move each control on its own:
   - **Natural scrolling** (`natural_scroll`)
   - **Clickfinger (2-finger right click)** (`clickfinger_behavior`)
   - **Disable while typing** (`disable_while_typing`)
   - **Scroll speed** (`scroll_factor`, `0.10` to `2.00`, applied ~250 ms after you stop)
3. Every control writes **only its own fields**: flipping a toggle does not add an `accel_profile` or a `sensitivity` you never asked for. You can leave the trackpad with no acceleration profile and no sensitivity so libinput keeps its defaults.

A typical result in `~/.config/hypr/input.lua`:

```lua
hl.device({ name = "apple-inc.-magic-trackpad", clickfinger_behavior = true, disable_while_typing = false, natural_scroll = false, scroll_factor = 0.8 })
```

Or the same setting from the CLI:

```bash
bin/mouse-tuner.sh set --device apple-inc.-magic-trackpad \
  --natural-scroll false --clickfinger true \
  --disable-while-typing false --scroll-factor 0.8
```

### Known limitation: Bluetooth and suspend

Over Bluetooth, after the machine suspends the Magic Trackpad 2 may:

- **not reconnect on its own**, or
- reconnect but with **multitouch gestures stopped** (the kernel does not re-initialize multitouch mode).

When that happens, reconnect it by hand (power-cycle it, or `bluetoothctl connect <MAC>`) or run a resume hook that forces the reconnect. Omarchy ships no suspend/resume hook directory, so the two clean options are:

- a script in `/usr/lib/systemd/system-sleep/` (system level, needs `sudo`), or
- a `systemd` user service with `After=suspend.target` that runs `bluetoothctl connect <MAC>` and `sleep 1`.

Until the device re-initializes, Hyprland may list it without gestures even though the Mouse Tuner settings are still applied.

---

## Troubleshooting

| Problem                        | Fix                                                                     |
| ------------------------------ | ----------------------------------------------------------------------- |
| No devices listed              | Run `hyprctl devices` and check the `mice:` section. Turn the mouse on.  |
| Settings did not apply         | `hyprctl configerrors` must be empty; then `hyprctl reload`.             |
| Widget missing from the bar    | `omarchy-shell shell rescanPlugins` or `omarchy restart shell`.          |
| A device is rejected           | Its name contains characters the engine refuses (`/`, quotes, `..`).     |
| A setting is rejected          | Only the fields in the CLI table are accepted; `tap-to-click` is global. |
| Touchpad not marked *(touchpad)* | It must appear in `mice[]` and its name must contain `touchpad` or `trackpad`. |
| Touchpad dead after suspend    | Reconnect it (`bluetoothctl connect <MAC>`); this is the Bluetooth limitation above. |

---

## Uninstall

```bash
omarchy plugin remove io.github.mrchispa.mouse-tuner
```

Before uninstalling, use **Reset device** (or `bin/mouse-tuner.sh reset`) if you also want to remove the saved settings from `input.lua`.

---

## License

MIT — see [LICENSE](LICENSE). © MrChispa.
