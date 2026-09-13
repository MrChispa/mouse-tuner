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
- 🖱️ **Por dispositivo**: el touchpad y otros punteros quedan intactos.
- ⚡ **Motor CLI independiente** (`bin/mouse-tuner.sh`), usable sin la barra.
- 🔒 **Escritura atómica con lock**: nada fuera de su bloque se toca, byte a byte.
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
5. **Reset device** elimina el ajuste y devuelve ese dispositivo al default del sistema.

El panel muestra el estado activo, por ejemplo `flat · -0.30`.

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
- Los datos de dispositivos se leen de `hyprctl devices -j`.

---

## Solución de problemas

| Problema                          | Solución                                                                 |
| --------------------------------- | ------------------------------------------------------------------------ |
| No aparecen dispositivos          | Ejecuta `hyprctl devices` y revisa la sección `mice:`. Enciende el mouse. |
| El ajuste no se aplica            | `hyprctl configerrors` debe estar vacío; luego `hyprctl reload`.          |
| El icono no aparece en la barra   | `omarchy-shell shell rescanPlugins` o `omarchy restart shell`.            |
| Un dispositivo es rechazado       | Su nombre tiene caracteres que el motor no escribe (`/`, comillas, `..`). |

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
- 🖱️ **Per device**: your touchpad and other pointers stay exactly as they were.
- ⚡ **Standalone CLI engine** (`bin/mouse-tuner.sh`), usable without the bar.
- 🔒 **Atomic, locked writes**: nothing outside its block is touched, byte for byte.
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
5. **Reset device** removes the override and returns that device to the system default.

The panel shows the active state, for example `flat · -0.30`.

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
- Device data comes from `hyprctl devices -j`.

---

## Troubleshooting

| Problem                        | Fix                                                                     |
| ------------------------------ | ----------------------------------------------------------------------- |
| No devices listed              | Run `hyprctl devices` and check the `mice:` section. Turn the mouse on.  |
| Settings did not apply         | `hyprctl configerrors` must be empty; then `hyprctl reload`.             |
| Widget missing from the bar    | `omarchy-shell shell rescanPlugins` or `omarchy restart shell`.          |
| A device is rejected           | Its name contains characters the engine refuses (`/`, quotes, `..`).     |

---

## Uninstall

```bash
omarchy plugin remove io.github.mrchispa.mouse-tuner
```

Before uninstalling, use **Reset device** (or `bin/mouse-tuner.sh reset`) if you also want to remove the saved settings from `input.lua`.

---

## License

MIT — see [LICENSE](LICENSE). © MrChispa.
