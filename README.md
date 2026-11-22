# HexShot

A local **screenshot and annotation** tool for macOS that never sends anything to the internet. Select an area, draw on it, then copy it to the clipboard or save it.

![HexShot](docs/screenshot.png)

## How to install & open
Requires macOS 14+ on an Apple Silicon Mac (M1 or later).

1. **[⬇ Download HexShot.dmg](https://github.com/Huseyinkayaw/HexShot/raw/main/release/HexShot.dmg)**
2. Open the DMG and drag **HexShot** into the **Applications** folder.
3. Open HexShot. Because the app is free and not notarized by Apple, macOS shows *"HexShot" Not Opened — Apple could not verify…*. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down to *"HexShot" was blocked…* and click **Open Anyway**, then enter your Mac password. You only need to do this once.
5. When asked, allow **Screen Recording** in System Settings → Privacy & Security.

Prefer Terminal? Steps 3–4 can be replaced with:

```bash
xattr -dr com.apple.quarantine /Applications/HexShot.app
```

SHA-256 of the DMG: `83361cb2ad78cb9b5afa4c22ec8f54b0240294d757d63d785e5ba56c7d6b2fc7`

## Features
- Region and full-screen capture (shortcuts assignable in Settings)
- Tools: pen, line, arrow, rectangle, ellipse, highlighter, text, blur (pixelate), numbered steps
- Single-key tool switching (`V P L A R E M T B` …), colors, stroke sizes, undo
- Copy with `⌘C` / `Enter` / double-click, save with `⌘S`
- Lives in the menu bar, optional launch at login

## Privacy & security
- Makes no network connections.
- Screenshots go only to the clipboard or to a file you choose; nothing is written anywhere else.
- Blur permanently destroys the pixels underneath (not a reversible filter).

## Build from source
Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools.

```bash
./build.sh               # build and install to /Applications
./build.sh --no-install  # build only (build/)
```
Requires **Screen Recording** permission on first use.

---

## Türkçe

macOS için yerel, internete hiçbir şey göndermeyen **ekran görüntüsü ve işaretleme** aracı. Alan seçin, üzerine çizin, panoya kopyalayın ya da kaydedin.

**Kurulum ve ilk açılış** (macOS 14+, Apple Silicon / M1 ve üstü)

1. **[⬇ HexShot.dmg dosyasını indirin](https://github.com/Huseyinkayaw/HexShot/raw/main/release/HexShot.dmg)**
2. DMG'yi açın ve **HexShot**'i **Uygulamalar** klasörüne sürükleyin.
3. HexShot'i açın. Uygulama ücretsiz olduğu ve Apple tarafından onaylanmadığı için macOS *"HexShot" Açılmadı — Apple … doğrulayamadı* uyarısı gösterir. **Bitti**'ye basın.
4. **Sistem Ayarları → Gizlilik ve Güvenlik**'i açın, aşağı inip *"HexShot" engellendi* satırındaki **Yine de Aç**'a tıklayın ve Mac şifrenizi girin. Bu yalnızca bir kez yapılır.
5. İstendiğinde Sistem Ayarları → Gizlilik ve Güvenlik'ten **Ekran Kaydı** izni verin.

Terminal kullanıyorsanız 3–4. adımların yerine: `xattr -dr com.apple.quarantine /Applications/HexShot.app`

DMG SHA-256: `83361cb2ad78cb9b5afa4c22ec8f54b0240294d757d63d785e5ba56c7d6b2fc7`

**Özellikler**
- Alan seçme ve tam ekran yakalama (kısayollar ayarlardan atanır)
- Araçlar: kalem, çizgi, ok, dikdörtgen, elips, fosforlu kalem, metin, bulanıklaştırma (pikselleştirme), numaralı adım
- Tek tuşla araç seçimi (`V P L A R E M T B` …), renkler, kalınlıklar, geri alma
- `⌘C` / `Enter` / çift tık ile panoya kopyala, `⌘S` ile kaydet
- Menü çubuğunda çalışır, girişte başlatılabilir

**Gizlilik ve güvenlik**
- İnternete bağlanmaz.
- Görüntü yalnızca panoya veya seçtiğiniz dosyaya gider.
- Bulanıklaştırma alttaki pikselleri kalıcı olarak yok eder (geri döndürülemez).

**Kaynaktan derleme:** macOS 14+, Apple Silicon ve Xcode Command Line Tools gerekir. `./build.sh` derler ve `/Applications`'a kurar; `--no-install` yalnızca derler. İlk kullanımda **Ekran Kaydı** izni gerekir.
