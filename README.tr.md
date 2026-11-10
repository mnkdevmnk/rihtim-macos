# Rıhtım

[English](README.md) · **Türkçe**

## Kurulum

### İndir (en kolayı)
1. [Son sürümden](https://github.com/mnkdevmnk/rihtim-macos/releases/latest) **Rihtim.dmg**'yi indir.
2. Aç ve **Rihtim**'i **Uygulamalar** klasörüne sürükle.
3. Uygulama Apple onaylı (notarize) değil, o yüzden macOS ilk açılışı engeller. Terminal'i aç ve şunu çalıştır:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Rihtim.app
   ```
   Ya da: bir kez açmayı dene, sonra Sistem Ayarları › Gizlilik ve Güvenlik'te **Yine de Aç**'a tıkla.
4. Rıhtım'ı aç ve istediği izinleri ver (aşağıda **İzinler**).

macOS 14 ve üstünde, Apple Silicon ve Intel Mac'lerde çalışır. Liquid Glass için macOS 26 gerekir; eski sürümlerde buzlu cam görünümü olur.

### Kendi Mac'inde derle
Gereken: macOS 14+, Xcode.
```bash
git clone https://github.com/mnkdevmnk/rihtim-macos.git
cd rihtim-macos
./build.sh install      # Rihtim.app derler, Rihtim.dmg'yi masaüstüne koyar, /Applications'a kurar
```

## Hakkında

Notch, Dock ve menü çubuğunu tek uygulamadan yöneten macOS eklentisi. Gerçek Dock'u bozmadan üstüne özellik ekler.

Rıhtım gerçek Dock'u gizlemez, kopyasını çizmez, `killall Dock` yapmaz ve `com.apple.dock` ayarlarına yazmaz. Dock'u Erişilebilirlik API'siyle sadece dinler ve widget'ları ayrı bir panel olarak yanına koyar.

## Özellikler

| Özellik | Ne yapar |
|---|---|
| **Dock önizlemeleri** | Dock ikonunun üstüne gelince pencerelerin canlı küçük resimleri çıkar; başka masaüstlerindeki pencereler de dahil. Tıklayınca o pencereye (gerekirse o masaüstüne) geçer, ✕ ile kapatır. |
| **⌘⇥ değiştirici** | Sistemin ⌘⇥'ının yerini alır. Uygulama ikonlarının üstünde seçili uygulamanın pencere önizlemeleri görünür. Menüden ⌥⇥'a da çevrilebilir. |
| **Müzik** | Apple Music ve Spotify'da çalan şarkı, kapak resmi, önceki / oynat / sonraki. Tıklayınca ilerleme çubuğu (sarılabilir) açılır. |
| **Sistem** | CPU % ve 45 sn'lik grafik, RAM, SSD, ağ ↓↑. Tıklayınca aranabilir işlem listesi açılır (CPU/Bellek sıralama, ✕ ile sonlandırma). |
| **Cihaz pilleri** | Mac, AirPods (sol / sağ / kutu), Magic Mouse, Keyboard, Trackpad. Şarj olanda ⚡ görünür. Gizle / başa sabitle, düşük pil bildirimi. |
| **Takvim** | Apple Takvim (EventKit): sıradaki etkinlik ve geri sayım, bugünün programı, istersen toplantı başlayınca Zoom/Meet/Teams bağlantısını açar. |
| **Hava durumu** | Open-Meteo: sıcaklık, hissedilen, 12 saatlik tahmin, nem, rüzgâr, UV, gün doğumu/batımı. Şehir ayarlardan. |
| **Kahve** | `caffeinate` gibi uyku engelleme: süresiz / 30 dk / 1-2-4 sa, ekran da açık kalsın seçeneği. |
| **Espresso** | Kapak kapalıyken de devam eden Kahve: Mac kapalıyken indirmeler ve derlemeler biter. Bir kez şifre ister; Kahve bitince, çıkışta, çökme sonrası ve pil azalınca normal kapak uykusu geri gelir. |
| **Claude kullanımı** | Claude aboneliğinin 5 saatlik ve haftalık limit doluluğu. |
| **Notch adası** | Notch'un iki yanında mini bilgi; fareyle açılınca müzik, sistem, Claude, uyku, hava ve piller. |
| **Menü çubuğu modülleri** | Stats gibi: CPU, GPU, RAM, disk, ağ, pil, dünya saatleri. Grafik / ikon / değer görünümleri; tıklayınca ayrıntı (en çok kaynak kullanan süreçler, bellek baskısı, swap, disk okuma/yazma, IP, pil sağlığı/döngü/sıcaklık/watt). |
| **Notch sekmeleri** | Raf (dosya sürükle-bırak), pano geçmişi, hızlı not, takvim ızgarası, ayna kamera. Kısa bildirimler: şarj, cihaz bağlandı, uyku engeli, 20-20-20 göz molası. |
| **Dil** | İngilizce, Türkçe, Almanca. Varsayılan olarak sistem dilini izler; Ayarlar › Genel'den değiştirilebilir. |
| **Ayarlar penceresi** | Her widget için aç/kapat ve Dock'un solu/sağı, takvim seçimi, şehir, pil ayarları. `.app` tekrar açılınca veya menüden ⌘, ile gelir. |

### ⌘⇥ kısayolları (⌘ basılıyken)
`⇥` / `⇧⇥` / `← →` uygulama seç · `↑ ↓` ya da `` ` `` pencere seç · `Q` uygulamadan çık · `H` gizle · `W` pencereyi kapat · `Esc` iptal · ⌘'yi bırakınca geçer

## İzinler
1. **Erişilebilirlik:** Dock'u dinlemek, pencereler ve ⌘⇥ için şart.
2. **Ekran Kaydı:** Canlı küçük resimler için. Verince menüden *"İzin verdim, yeniden başlat"* seç.
3. **Otomasyon (Music / Spotify):** Şarkı ilk çaldığında sorulur.

## Bilinen sınırlar
- Başka Space'teki pencereler için AltTab'ın yarı-private yöntemleri (`_AXUIElementCreateWithRemoteToken`, SkyLight odaklama) kullanılıyor; macOS güncellemesi bunları bozarsa sadece o Space'teki pencereler listelenir.
- ⌘⇥ devralma, AltTab'ın da kullandığı bir SkyLight fonksiyonuyla yapılıyor. Rıhtım çökse bile sistem ⌘⇥ geri açılır. Açılmazsa oturumu kapatıp açmak yeter.
- Widget şeridi sadece Dock alttayken görünür. Dock otomatik gizleniyorsa fare alta inince açılır. Yer yetmezse widget'lar kompakta geçer ya da gizlenir.
- Müzik araması ve iPhone pili yok. İkisi için de herkese açık bir macOS API'si yok.

## Lisans
[MIT](LICENSE)
