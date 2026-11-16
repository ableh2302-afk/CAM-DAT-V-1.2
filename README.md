# Cam Dat

Kamera dokumentasi offline dengan penamaan foto otomatis dari data Excel.

## Fitur
- Tampilan kamera ala aplikasi kamera Android: layar penuh, tap untuk fokus, geser untuk exposure, cubit untuk zoom, pilihan zoom 1x/2x/5x
- Rasio: Layar penuh, 4:3, 16:9, 1:1 (hasil foto sama persis dengan yang terlihat di layar)
- Kualitas foto: HD, Full HD, Tinggi (±4K, default), Maksimal
- Flash: mati / auto / nyala / senter; timer 3/5/10 detik; grid
- Penamaan foto:
  - **Otomatis**: ketik NO, nama item muncul dari Excel yang di-import (kolom A = NO, kolom B = Nama). Format: `NO_Nama`, `Nama`, atau `NO`
  - **Manual**: ketik nama bebas; kosong = `FOTO_tanggal_jam`
  - Nama yang sama otomatis diberi akhiran `_1`, `_2`, ...
- Foto disimpan di latar belakang, jadi bisa langsung jepret lagi
- Halaman Status (sudah / belum difoto), galeri, dan editor foto

## Build APK
Lewat GitHub: tab **Actions → Build APK → Run workflow**, lalu unduh artifact `cam-dat-apk`.

Atau lokal:
```bash
flutter pub get
flutter build apk --release
```
APK: `build/app/outputs/flutter-apk/app-release.apk`
