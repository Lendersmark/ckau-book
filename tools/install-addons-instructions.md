# 🧩 ckau-book Addons Manager for Batocera

This script automates the **installation, update, and removal** of the [ckau-book](https://github.com/CkauNui/ckau-book) theme and its addons for **Batocera EmulationStation**.

It manages all related repositories, tracks their installed versions, and keeps your setup synchronized with the latest commits on GitHub — all through a simple **interactive menu** or **CLI interface**.

---

## ✨ Features

- 🧭 **Interactive TUI menu** with options to install, update, remove, list, or exit  
- 🗂 **Hardcoded catalog** of supported addons (ckau-book and its official extensions)
- ⚙️ **Per-addon tracking** via manifest and commit SHA files
- 🧱 **Automatic detection** of manually pre-installed content
- 🔄 **Resync mechanism** if files change outside the script (manual edits, EmulationStation updates, etc.)
- 💾 **Optional backup** before writing new data
- 🧹 **Automatic cleanup** of temporary directories
- 🧰 **Non-interactive CLI mode** for automation or scripting

---

## 📦 Included Addons

| Name | Repository | Description |
|------|-------------|-------------|
| **Theme** | `CkauNui/ckau-book` | Base theme core |
| **Colorful-4K-Images** | `CkauNui/ckau-book-addons-Colorful-4K-Images` | High-resolution system images |
| **Colorful-Video** | `CkauNui/ckau-book-addons-Colorful-Video` | Colorful system video assets |
| **Cinematic-Video** | `CkauNui/ckau-book-addons-Cinematic-Video` | Cinematic system videos |
| **Consoles** | `CkauNui/ckau-book-addons-Consoles` | Console artwork and assets |
| **Wallpapers** | `CkauNui/ckau-book-addons-Wallpapers` | Themed wallpaper collection |

---

## ⚙️ Requirements

The script depends on standard Unix utilities available on most Batocera systems:

```
curl, unzip, tar, sed, awk, diff
```

---

## 📁 Default Paths and Environment Variables

| Variable | Default | Description |
|-----------|----------|-------------|
| `THEMES_DIR` | `/userdata/themes` | Base folder for all themes |
| `BACKUP` | `0` | Set to `1` to create a backup before installing |
| `BRANCH` | `main` | Default branch when unspecified |
| `KEEP_TMP` | `0` | Keep temporary work directories for debugging |
| `TMP_BASE` | `${THEMES_DIR}/.tmp` | Temporary working directory |
| `ALLOW_THEME_REMOVE` | `0` | Must be `1` to remove the core `ckau-book` theme |
| `DEEP_REMOVE` | `0` | Set to `1` to attempt cleanup when no manifest exists |

---

## 🚀 Usage

### 🧩 Interactive Mode
Run the script without arguments to launch the menu interface:

```bash
./install-addons-batocera.sh
```

You’ll see a list of all addons with their installation status:

```
[✓] = installed   [ ] = not installed
```

Menu options:
1. **Install / Update** selected addons  
2. **Remove** selected addons  
3. **Refresh** list (rebuilds tracking)  
0. **Exit**

Press `F5` in EmulationStation after any installation to reload the theme.

---

### 🧠 Command-Line Mode

Run directly from terminal or from a custom script.

#### List all addons and their status
```bash
./install-addons-batocera.sh list
```

#### Install or update one addon
```bash
./install-addons-batocera.sh install Colorful-Video
```

#### Install or update all addons
```bash
./install-addons-batocera.sh install all
```

#### Remove one addon
```bash
./install-addons-batocera.sh remove Consoles
```

#### Remove all addons
```bash
./install-addons-batocera.sh remove all
```

---

## 🧩 How It Works

### 1. **Tracking System**
Each installed repository has:
- A **manifest file** listing every installed file (under `.ckau-installed/manifests/`)
- A **commit SHA file** recording the latest GitHub commit

These files allow precise uninstalling and detection of manual file edits.

### 2. **Bootstrap Detection**
If a theme or addon already exists locally but isn’t tracked yet,  
the script automatically builds a manifest and fetches the current remote SHA —  
so it can be updated safely later.

### 3. **Auto-Resync**
When the local file list differs from the manifest (e.g. manual edits),  
the script rebuilds the manifest and updates the stored SHA accordingly.

### 4. **Safe Removal**
When removing an addon, files are deleted **only** if not shared with other addons.  
No unrelated content is touched.

---

## 🪄 Advanced Options

- `BACKUP=1`  
  → Creates a tar.gz backup under `/userdata/system/backups/`
- `KEEP_TMP=1`  
  → Keeps temp directories for inspection after run
- `DEEP_REMOVE=1`  
  → Reconstructs file list from the GitHub ZIP if the manifest is missing
- `ALLOW_THEME_REMOVE=1`  
  → Allows deletion of the main `ckau-book` theme (normally blocked)

---

## 🧹 Example Workflow

```bash
# Update all installed addons
./install-addons-batocera.sh install all

# Remove an unwanted addon
./install-addons-batocera.sh remove Wallpapers

# Rebuild tracking info after manual changes
./install-addons-batocera.sh list
```

---

## 🧾 Logs and Versioning

Each action logs its output with the prefix:
```
[ckau-addon v1.4.0]
```

Manifests, SHA files, and backups are stored inside:

```
/userdata/themes/.ckau-installed/
```

---

## 🧑‍💻 Author & Credits

Created by **Lendersmark**  
Tested on **Batocera Linux 42**
