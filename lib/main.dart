import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

late List<CameraDescription> cameras;

const Color _accent = Color(0xFFFFC107);
const Color _sheetBg = Color(0xFF1B1D22);

final ThemeData _darkTheme = ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  colorSchemeSeed: const Color(0xFF1E6FE8),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = <CameraDescription>[];
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CamDatApp());
}

class CamDatApp extends StatelessWidget {
  const CamDatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Cam Dat',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1E6FE8),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      ),
      home: const CameraHomePage(),
    );
  }
}

enum CameraRatio { full, r4x3, r16x9, r1x1 }

enum NamingMode { auto, manual }

enum AutoFormat { noName, nameOnly, noOnly }

enum FlashSetting { off, auto, on, torch }

class _QualityOption {
  final String key;
  final ResolutionPreset preset;
  final String title;
  final String subtitle;
  const _QualityOption(this.key, this.preset, this.title, this.subtitle);
}

const List<_QualityOption> _qualityOptions = [
  _QualityOption('hd', ResolutionPreset.high, 'HD', 'Ringan & cepat (±720p)'),
  _QualityOption('fhd', ResolutionPreset.veryHigh, 'Full HD', 'Seimbang (±1080p)'),
  _QualityOption('uhd', ResolutionPreset.ultraHigh, 'Tinggi (disarankan)', 'Tajam seperti kamera HP (±4K)'),
  _QualityOption('max', ResolutionPreset.max, 'Maksimal', 'Resolusi tertinggi sensor, simpan lebih lama'),
];

/// Berjalan di isolate terpisah agar UI tidak macet saat memproses foto
/// resolusi besar. Meluruskan orientasi lalu memotong sesuai rasio layar.
Uint8List _processPhotoJob(Map<String, dynamic> args) {
  final raw = args['bytes'] as Uint8List;
  final target = args['ratio'] as double;
  var image = img.decodeImage(raw);
  if (image == null) throw Exception('Foto tidak dapat dibaca.');
  image = img.bakeOrientation(image);
  final current = image.width / image.height;
  if (target > 0 && (current - target).abs() > .01) {
    var w = image.width;
    var h = image.height;
    if (current > target) {
      w = (image.height * target).round();
    } else {
      h = (image.width / target).round();
    }
    image = img.copyCrop(
      image,
      x: (image.width - w) ~/ 2,
      y: (image.height - h) ~/ 2,
      width: w,
      height: h,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

const MethodChannel _nativeChannel = MethodChannel('dokumentasi_barang_pecah/media_store');

Future<void> _shareFilesNative(List<String> paths, String mime) =>
    _nativeChannel.invokeMethod('shareFiles', <String, dynamic>{'paths': paths, 'mime': mime});

Future<String?> _zipFilesNative(List<String> paths, String zipName) =>
    _nativeChannel.invokeMethod<String>('zipFiles', <String, dynamic>{'paths': paths, 'zipName': zipName});

Future<void> _deleteGalleryCopies(List<String> names) async {
  try {
    await _nativeChannel.invokeMethod('deleteGallery', <String, dynamic>{
      'names': names,
      'relativePath': 'Pictures/Dokumentasi Barang Pecah',
    });
  } catch (_) {}
}

String _zipTimestampName() {
  final n = DateTime.now();
  String t(int v) => v.toString().padLeft(2, '0');
  return 'CamDat_${n.year}${t(n.month)}${t(n.day)}_${t(n.hour)}${t(n.minute)}${t(n.second)}.zip';
}

class CameraHomePage extends StatefulWidget {
  const CameraHomePage({super.key});
  @override
  State<CameraHomePage> createState() => _CameraHomePageState();
}

class _CameraHomePageState extends State<CameraHomePage> with WidgetsBindingObserver {
  static const MethodChannel _mediaStore = MethodChannel('dokumentasi_barang_pecah/media_store');
  static const _folderPath = 'Pictures/Dokumentasi Barang Pecah';

  CameraController? _camera;
  int _cameraIndex = 0;
  int _cameraInitToken = 0;
  bool _initializing = true;
  bool _slowInit = false;
  bool _cameraBusy = false;
  bool _permissionDenied = false;
  bool _capturing = false;
  bool _shutterFlash = false;
  int _savingCount = 0;
  int _countdown = 0;

  FlashSetting _flash = FlashSetting.off;
  bool _gridOn = false;
  int _timerSeconds = 0;

  double _zoom = 1.0;
  double _appliedZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  bool _zoomBusy = false;

  double _exposure = 0.0;
  double _minExposure = 0.0;
  double _maxExposure = 0.0;

  Offset? _focusPoint;
  bool _focusVisible = false;
  Timer? _focusTimer;

  CameraRatio _ratio = CameraRatio.full;
  String _qualityKey = 'uhd';
  double _viewportRatio = 0;

  NamingMode _naming = NamingMode.auto;
  AutoFormat _autoFormat = AutoFormat.noName;
  final _numberController = TextEditingController();
  final _nameController = TextEditingController();

  Map<String, String> _barang = {};
  Map<String, List<String>> _photoHistory = {};
  String? _latestPhoto;
  List<File> _photos = [];
  Future<void> _saveQueue = Future<void>.value();
  final Set<String> _pendingBases = {};
  bool _confirming = false;

  ResolutionPreset get _preset =>
      _qualityOptions.firstWhere((q) => q.key == _qualityKey, orElse: () => _qualityOptions[2]).preset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _immersive();
    _start();
  }

  void _immersive() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // ───────────────────────── Startup ─────────────────────────

  Future<void> _start() async {
    // Semua yang tidak bergantung pada kamera dijalankan paralel sehingga
    // kamera bisa dibuka secepat mungkin.
    final prefsFuture = _loadPreferences();
    final dataFuture = Future.wait([_loadDatabase(), _loadPhotoHistory()]);
    final granted = await _requestPermissions();
    await prefsFuture;

    if (!granted) {
      if (mounted) {
        setState(() {
          _permissionDenied = true;
          _initializing = false;
        });
      }
      return;
    }
    if (mounted && _permissionDenied) setState(() => _permissionDenied = false);

    try {
      cameras = await availableCameras();
    } catch (e) {
      cameras = <CameraDescription>[];
      if (mounted) _message('Kamera tidak tersedia: $e');
    }

    if (cameras.isNotEmpty && mounted) {
      final back = cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _cameraIndex = back < 0 ? 0 : back;
      await _initializeCamera();
    } else if (mounted) {
      setState(() => _initializing = false);
    }

    await dataFuture;
    if (mounted) setState(() {});
    unawaited(_refreshPhotos());
  }

  Future<bool> _requestPermissions() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _loadPreferences() async {
    final p = await SharedPreferences.getInstance();
    _ratio = switch (p.getString('cam_ratio_v2')) {
      '4:3' => CameraRatio.r4x3,
      '16:9' => CameraRatio.r16x9,
      '1:1' => CameraRatio.r1x1,
      _ => CameraRatio.full,
    };
    final q = p.getString('cam_quality_v2');
    if (q != null && _qualityOptions.any((o) => o.key == q)) _qualityKey = q;
    _naming = p.getString('naming_mode') == 'manual' ? NamingMode.manual : NamingMode.auto;
    _autoFormat = switch (p.getString('auto_format')) {
      'name' => AutoFormat.nameOnly,
      'no' => AutoFormat.noOnly,
      _ => AutoFormat.noName,
    };
    _gridOn = p.getBool('cam_grid') ?? false;
    _timerSeconds = p.getInt('cam_timer') ?? 0;
  }

  Future<void> _savePreferences() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('cam_ratio_v2', _ratioText);
    await p.setString('cam_quality_v2', _qualityKey);
    await p.setString('naming_mode', _naming == NamingMode.manual ? 'manual' : 'auto');
    await p.setString(
      'auto_format',
      switch (_autoFormat) { AutoFormat.nameOnly => 'name', AutoFormat.noOnly => 'no', _ => 'no_name' },
    );
    await p.setBool('cam_grid', _gridOn);
    await p.setInt('cam_timer', _timerSeconds);
  }

  String get _ratioText => switch (_ratio) {
        CameraRatio.full => 'FULL',
        CameraRatio.r4x3 => '4:3',
        CameraRatio.r16x9 => '16:9',
        CameraRatio.r1x1 => '1:1',
      };

  /// Rasio lebar/tinggi jendela preview dalam orientasi portrait.
  double _portraitRatio(CameraRatio r) => switch (r) {
        CameraRatio.full => 0,
        CameraRatio.r4x3 => 3 / 4,
        CameraRatio.r16x9 => 9 / 16,
        CameraRatio.r1x1 => 1,
      };

  Future<void> _loadPhotoHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('photo_history');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _photoHistory = decoded.map(
          (k, v) => MapEntry(k.toString(), (v is List ? v.map((e) => e.toString()).toList() : <String>[])),
        );
      }
    } catch (_) {
      _photoHistory = {};
    }
  }

  Future<void> _savePhotoHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('photo_history', jsonEncode(_photoHistory));
  }

  Future<void> _loadDatabase() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('excel_database');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _barang = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      _barang = {};
    }
  }

  // ───────────────────────── Camera ─────────────────────────

  FlashMode _flashMode(FlashSetting f) => switch (f) {
        FlashSetting.off => FlashMode.off,
        FlashSetting.auto => FlashMode.auto,
        FlashSetting.on => FlashMode.always,
        FlashSetting.torch => FlashMode.torch,
      };

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty || _cameraBusy || !mounted) return;

    _cameraBusy = true;
    final token = ++_cameraInitToken;
    final selected = cameras[_cameraIndex.clamp(0, cameras.length - 1)];

    // Hanya boleh ada satu CameraController yang memegang kamera.
    final old = _camera;
    _camera = null;
    setState(() {
      _initializing = true;
      _slowInit = false;
    });
    // Spinner hanya muncul bila pembukaan kamera benar-benar lambat,
    // sehingga bukaan normal tidak berkedip.
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _initializing && token == _cameraInitToken) setState(() => _slowInit = true);
    });
    try {
      await old?.dispose();
    } catch (_) {}

    if (!mounted || token != _cameraInitToken) {
      _cameraBusy = false;
      return;
    }

    final controller = CameraController(
      selected,
      _preset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      if (!mounted || token != _cameraInitToken) {
        await controller.dispose();
        _cameraBusy = false;
        return;
      }
      _camera = controller;
      _cameraBusy = false;
      setState(() {
        _initializing = false;
        _slowInit = false;
      });
      unawaited(_applyCameraSettings(controller, token));
    } catch (e) {
      try {
        await controller.dispose();
      } catch (_) {}
      _cameraBusy = false;
      if (mounted && token == _cameraInitToken) {
        setState(() {
          _initializing = false;
          _slowInit = false;
        });
        _message('Kamera gagal dibuka: $e');
      }
    }
  }

  Future<void> _applyCameraSettings(CameraController c, int token) async {
    bool valid() => mounted && token == _cameraInitToken && identical(_camera, c);

    // Pastikan auto-exposure & auto-focus aktif agar gambar tidak gelap.
    try {
      await c.setExposureMode(ExposureMode.auto);
    } catch (_) {}
    try {
      await c.setFocusMode(FocusMode.auto);
    } catch (_) {}

    try {
      final minZ = await c.getMinZoomLevel();
      final maxZ = await c.getMaxZoomLevel();
      if (!valid()) return;
      _minZoom = minZ;
      _maxZoom = maxZ;
      _zoom = math.min(math.max(1.0, minZ), maxZ);
      _appliedZoom = _zoom;
      await c.setZoomLevel(_zoom);
    } catch (_) {}

    try {
      final minE = await c.getMinExposureOffset();
      final maxE = await c.getMaxExposureOffset();
      if (!valid()) return;
      _minExposure = minE;
      _maxExposure = maxE;
      _exposure = 0;
      await c.setExposureOffset(0);
    } catch (_) {}

    if (_flash != FlashSetting.off) {
      try {
        await c.setFlashMode(_flashMode(_flash));
      } catch (_) {}
    }
    if (valid()) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _handleCameraPaused();
    } else if (state == AppLifecycleState.resumed) {
      _immersive();
      _handleCameraResumed();
    }
  }

  Future<void> _handleCameraPaused() async {
    ++_cameraInitToken;
    _cameraBusy = false;
    final camera = _camera;
    _camera = null;
    if (mounted) setState(() => _initializing = true);
    try {
      await camera?.dispose();
    } catch (_) {}
  }

  Future<void> _handleCameraResumed() async {
    if (!mounted) return;
    if (_permissionDenied) {
      await _start();
      return;
    }
    if (cameras.isEmpty || _camera != null || _cameraBusy) return;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted || _camera != null || _cameraBusy) return;
    await _initializeCamera();
  }

  Future<void> _cycleFlash() async {
    final next = FlashSetting.values[(_flash.index + 1) % FlashSetting.values.length];
    final cam = _camera;
    setState(() => _flash = next);
    if (cam == null) return;
    try {
      await cam.setFlashMode(_flashMode(next));
    } catch (_) {
      if (mounted) setState(() => _flash = FlashSetting.off);
      _message('Flash tidak didukung kamera ini.');
    }
  }

  Future<void> _cycleTimer() async {
    const steps = [0, 3, 5, 10];
    setState(() => _timerSeconds = steps[(steps.indexOf(_timerSeconds) + 1) % steps.length]);
    await _savePreferences();
  }

  Future<void> _cycleRatio() async {
    setState(() => _ratio = CameraRatio.values[(_ratio.index + 1) % CameraRatio.values.length]);
    await _savePreferences();
  }

  Future<void> _switchCamera() async {
    if (cameras.length < 2 || _cameraBusy || !mounted) return;
    final current = cameras[_cameraIndex.clamp(0, cameras.length - 1)].lensDirection;
    var next = cameras.indexWhere((c) => c.lensDirection != current);
    if (next < 0) next = (_cameraIndex + 1) % cameras.length;
    _cameraIndex = next;
    await _initializeCamera();
  }

  Size _previewSize(CameraController c) {
    final ps = c.value.previewSize;
    if (ps == null || ps.width <= 0 || ps.height <= 0) return const Size(3, 4);
    return Size(math.min(ps.width, ps.height), math.max(ps.width, ps.height));
  }

  Offset _toSensorPoint(Offset local, Size viewport, Size preview) {
    final pa = preview.width / preview.height;
    final va = viewport.width / viewport.height;
    var nx = local.dx / viewport.width;
    var ny = local.dy / viewport.height;
    if (va < pa) {
      nx = 0.5 + (nx - 0.5) * (va / pa);
    } else {
      ny = 0.5 + (ny - 0.5) * (pa / va);
    }
    return Offset(nx.clamp(0.0, 1.0).toDouble(), ny.clamp(0.0, 1.0).toDouble());
  }

  void _bumpFocusTimer() {
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 3000), () {
      if (mounted) setState(() => _focusVisible = false);
    });
  }

  Future<void> _onTapFocus(Offset local, Size viewport) async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    setState(() {
      _focusPoint = local;
      _focusVisible = true;
    });
    _bumpFocusTimer();
    final p = _toSensorPoint(local, viewport, _previewSize(cam));
    try {
      await cam.setFocusPoint(p);
      await cam.setExposurePoint(p);
    } catch (_) {}
  }

  Future<void> _setZoom(double value) async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    final v = value.clamp(_minZoom, _maxZoom).toDouble();
    if ((v - _zoom).abs() < 0.005) return;
    setState(() => _zoom = v);
    if (_zoomBusy) return;
    _zoomBusy = true;
    try {
      while ((_appliedZoom - _zoom).abs() > 0.005) {
        final z = _zoom;
        try {
          await cam.setZoomLevel(z);
        } catch (_) {}
        _appliedZoom = z;
      }
    } finally {
      _zoomBusy = false;
    }
  }

  Future<void> _setExposure(double v) async {
    setState(() => _exposure = v);
    _bumpFocusTimer();
    try {
      await _camera?.setExposureOffset(v);
    } catch (_) {}
  }

  // ───────────────────────── Excel & penamaan ─────────────────────────

  String _normalizeNumber(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    final noLeading = v.replaceFirst(RegExp(r'^0+'), '');
    return noLeading.isEmpty ? '0' : noLeading;
  }

  String? _findBarang(String input) {
    final wanted = _normalizeNumber(input);
    if (wanted.isEmpty) return null;
    final direct = _barang[input.trim()];
    if (direct != null) return direct;
    for (final entry in _barang.entries) {
      if (_normalizeNumber(entry.key) == wanted) return entry.value;
    }
    return null;
  }

  List<MapEntry<String, String>> _suggestions(String query) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final nq = _normalizeNumber(q);
    final lq = q.toLowerCase();
    final out = <MapEntry<String, String>>[];
    for (final e in _barang.entries) {
      if (_normalizeNumber(e.key).startsWith(nq) || e.value.toLowerCase().contains(lq)) {
        out.add(e);
      }
    }
    out.sort((a, b) {
      final ea = _normalizeNumber(a.key) == nq ? 0 : 1;
      final eb = _normalizeNumber(b.key) == nq ? 0 : 1;
      return ea.compareTo(eb);
    });
    return out.take(6).toList();
  }

  String _cellText(dynamic cell) {
    final v = cell?.value;
    if (v == null) return '';
    var s = v.toString().trim();
    final m = RegExp(r'^(-?\d+)\.0+$').firstMatch(s);
    if (m != null) s = m.group(1)!;
    return s;
  }

  Future<void> _importExcel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (result == null || result.files.single.path == null) return;
      final bytes = await File(result.files.single.path!).readAsBytes();
      final workbook = excel.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) {
        _message('Excel tidak memiliki sheet.');
        return;
      }
      final rows = workbook.tables.values.first.rows;
      final imported = <String, String>{};
      // Baris pertama dianggap judul kolom, kecuali kolom A-nya angka murni.
      var start = 0;
      if (rows.isNotEmpty && rows.first.isNotEmpty) {
        final first = _cellText(rows.first[0]);
        if (!RegExp(r'^\d+$').hasMatch(first)) start = 1;
      }
      for (var i = start; i < rows.length; i++) {
        if (rows[i].length < 2) continue;
        final no = _cellText(rows[i][0]);
        final name = _cellText(rows[i][1]);
        if (no.isNotEmpty && name.isNotEmpty) imported[no] = name;
      }
      if (imported.isEmpty) {
        _message('Tidak ditemukan data pada kolom A dan B.');
        return;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('excel_database', jsonEncode(imported));
      if (mounted) setState(() => _barang = imported);
      _message('Berhasil import ${imported.length} data barang.');
    } catch (e) {
      _message('Gagal membaca Excel: $e');
    }
  }

  Future<void> _resetDatabase() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus data Excel?'),
        content: const Text('Foto yang sudah tersimpan tidak ikut dihapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('HAPUS')),
        ],
      ),
    );
    if (yes != true) return;
    final p = await SharedPreferences.getInstance();
    await p.remove('excel_database');
    if (!mounted) return;
    setState(() {
      _barang = {};
      _numberController.clear();
    });
    _message('Data Excel dihapus. Kamera tetap bisa digunakan.');
  }

  String _cleanName(String text) {
    var s = text.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.length > 120) s = s.substring(0, 120).trim();
    return s.isEmpty ? 'Barang' : s;
  }

  String _timestampName() {
    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    return 'FOTO_${n.year}${t(n.month)}${t(n.day)}_${t(n.hour)}${t(n.minute)}${t(n.second)}';
  }

  /// Menentukan nama file (tanpa .jpg) sesuai mode yang dipilih.
  /// `key` terisi hanya bila foto cocok dengan item Excel (untuk halaman Status).
  ({String base, String? key}) _resolveName() {
    if (_naming == NamingMode.manual) {
      final text = _nameController.text.trim();
      return (base: text.isEmpty ? _timestampName() : _cleanName(text), key: null);
    }
    final no = _numberController.text.trim();
    if (no.isEmpty) return (base: _timestampName(), key: null);
    final matched = _findBarang(no);
    if (matched == null) return (base: '${_cleanName(no)}_FOTO', key: null);
    final key = _normalizeNumber(no);
    final base = switch (_autoFormat) {
      AutoFormat.noName => '${_cleanName(no)}_${_cleanName(matched)}',
      AutoFormat.nameOnly => _cleanName(matched),
      AutoFormat.noOnly => _cleanName(no),
    };
    return (base: base, key: key);
  }

  // ───────────────────────── Simpan foto ─────────────────────────

  Future<Directory> _photoDirectory() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory();
    }
    final dir = Directory('${(base ?? await getApplicationDocumentsDirectory()).path}/Dokumentasi Barang Pecah');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _uniqueFile(Directory dir, String baseName) async {
    var f = File('${dir.path}/$baseName.jpg');
    var n = 1;
    while (await f.exists()) {
      f = File('${dir.path}/${baseName}_$n.jpg');
      n++;
    }
    return f;
  }

  Future<void> _saveToGallery(Uint8List bytes, String filename) async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaStore.invokeMethod('saveImage', <String, dynamic>{
        'bytes': bytes,
        'displayName': filename,
        'relativePath': _folderPath,
      });
    } on PlatformException {
      // Penyimpanan lokal tetap dipertahankan bila MediaStore gagal.
    }
  }

  Future<void> _refreshPhotos() async {
    try {
      final dir = await _photoDirectory();
      final entries = <MapEntry<File, DateTime>>[];
      for (final f in dir.listSync().whereType<File>()) {
        final p = f.path.toLowerCase();
        if (p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.png')) {
          entries.add(MapEntry(f, f.statSync().modified));
        }
      }
      entries.sort((a, b) => b.value.compareTo(a.value));
      final files = entries.map((e) => e.key).toList();
      if (mounted) {
        setState(() {
          _photos = files;
          _latestPhoto = files.isEmpty ? null : files.first.path;
        });
      }
    } catch (_) {}
  }

  /// Bila nama file sudah dipakai, tampilkan peringatan. Mengembalikan true
  /// jika pengguna memilih tetap lanjut (nama akan diberi nomor urut _1, _2, ...).
  Future<bool> _confirmDuplicate(String base) async {
    final dir = await _photoDirectory();
    bool taken(String n) => File('${dir.path}/$n.jpg').existsSync();
    if (!taken(base) && !_pendingBases.contains(base)) return true;
    var n = 1;
    while (taken('${base}_$n')) {
      n++;
    }
    if (!mounted) return false;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 36),
        title: const Text('Nama sudah ada'),
        content: Text('"$base.jpg" sudah dipakai.\n\nJika tetap lanjut, foto akan disimpan dengan nomor urut:\n${base}_$n.jpg'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'rename'), child: const Text('UBAH NAMA')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'go'), child: const Text('LANJUT FOTO')),
        ],
      ),
    );
    _immersive();
    if (choice == 'rename') {
      await _showNameSheet();
      return false;
    }
    return choice == 'go';
  }

  Future<void> _takePhoto() async {
    if (_capturing || _countdown > 0 || _confirming) return;
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || camera.value.isTakingPicture) {
      _message('Kamera belum siap.');
      return;
    }

    _confirming = true;
    final proceed = await _confirmDuplicate(_resolveName().base);
    _confirming = false;
    if (!proceed || !mounted || !identical(camera, _camera)) return;

    if (_timerSeconds > 0) {
      for (var i = _timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _countdown = i);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() => _countdown = 0);
      if (!identical(camera, _camera)) return;
    }

    setState(() => _capturing = true);
    HapticFeedback.lightImpact();
    try {
      final photo = await camera.takePicture();
      if (!mounted) return;
      // Nama & rasio ditetapkan saat shutter ditekan.
      final name = _resolveName();
      final ratio = _viewportRatio;
      setState(() {
        _capturing = false;
        _shutterFlash = true;
      });
      Future<void>.delayed(const Duration(milliseconds: 110), () {
        if (mounted) setState(() => _shutterFlash = false);
      });
      _enqueueSave(photo.path, ratio, name.base, name.key);
    } catch (e) {
      if (mounted) setState(() => _capturing = false);
      _message('Gagal mengambil foto: $e');
    }
  }

  /// Pemrosesan dilakukan di antrean latar belakang, sehingga foto berikutnya
  /// bisa langsung diambil tanpa menunggu foto sebelumnya selesai disimpan.
  void _enqueueSave(String src, double ratio, String baseName, String? key) {
    _pendingBases.add(baseName);
    setState(() => _savingCount++);
    _saveQueue = _saveQueue.then((_) => _processAndSave(src, ratio, baseName, key));
  }

  Future<void> _processAndSave(String src, double ratio, String baseName, String? key) async {
    try {
      final dir = await _photoDirectory();
      final target = await _uniqueFile(dir, baseName);
      final fileName = target.path.split(Platform.pathSeparator).last;

      // Jalur cepat: potong & simpan secara native (beberapa ratus ms).
      var done = false;
      if (Platform.isAndroid) {
        try {
          done = await _mediaStore.invokeMethod<bool>('processPhoto', <String, dynamic>{
                'src': src,
                'dest': target.path,
                'displayName': fileName,
                'relativePath': _folderPath,
                'ratio': ratio,
              }) ??
              false;
        } on PlatformException {
          done = false;
        }
      }
      // Cadangan bila jalur native gagal.
      if (!done) {
        final raw = await File(src).readAsBytes();
        final bytes = await compute(_processPhotoJob, <String, dynamic>{'bytes': raw, 'ratio': ratio});
        await target.writeAsBytes(bytes, flush: true);
        await _saveToGallery(bytes, fileName);
      }

      if (key != null) {
        _photoHistory.putIfAbsent(key, () => <String>[]).add(target.path);
        await _savePhotoHistory();
      }
      try {
        await File(src).delete();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _photos = [target, ..._photos];
          _latestPhoto = target.path;
        });
      }
      _message('Tersimpan: $fileName');
    } catch (e) {
      _message('Gagal menyimpan foto: $e');
    } finally {
      _pendingBases.remove(baseName);
      if (mounted) setState(() => _savingCount--);
    }
  }

  // ───────────────────────── Navigasi & pesan ─────────────────────────

  Future<void> _showGallery() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PhotoGalleryPage(photos: _photos, onChanged: _refreshPhotos)),
    );
    await _refreshPhotos();
    await _pruneHistory();
    _immersive();
  }

  /// Buang catatan "sudah difoto" untuk foto yang sudah dihapus dari galeri.
  Future<void> _pruneHistory() async {
    var changed = false;
    for (final key in _photoHistory.keys.toList()) {
      final list = _photoHistory[key]!;
      final alive = list.where((p) => File(p).existsSync()).toList();
      if (alive.length != list.length) {
        changed = true;
        if (alive.isEmpty) {
          _photoHistory.remove(key);
        } else {
          _photoHistory[key] = alive;
        }
      }
    }
    if (changed) {
      await _savePhotoHistory();
      if (mounted) setState(() {});
    }
  }

  Future<void> _showStatus() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PhotoStatusPage(barang: _barang, history: _photoHistory)),
    );
    _immersive();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 230),
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _focusTimer?.cancel();
    _camera?.dispose();
    _numberController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // ───────────────────────── Sheet: penamaan ─────────────────────────

  Future<void> _showNameSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _sheetBg,
      builder: (_) => Theme(
        data: _darkTheme,
        child: StatefulBuilder(
          builder: (ctx, setSheet) {
            final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
            void refresh() {
              setState(() {});
              setSheet(() {});
            }

            final auto = _naming == NamingMode.auto;
            final numeric = _barang.isEmpty || _barang.keys.every((k) => RegExp(r'^\d+$').hasMatch(k));
            final entered = _numberController.text.trim();
            final matched = auto ? _findBarang(entered) : null;
            final preview = _resolveName();

            return Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, bottom + 16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Penamaan Foto', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<NamingMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: NamingMode.auto, icon: Icon(Icons.auto_awesome, size: 18), label: Text('Otomatis')),
                          ButtonSegment(value: NamingMode.manual, icon: Icon(Icons.edit_outlined, size: 18), label: Text('Manual')),
                        ],
                        selected: {_naming},
                        onSelectionChanged: (s) {
                          _naming = s.first;
                          refresh();
                          _savePreferences();
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (auto) ...[
                      TextField(
                        controller: _numberController,
                        autofocus: true,
                        keyboardType: numeric ? TextInputType.number : TextInputType.text,
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          labelText: 'Ketik NO barang',
                          prefixIcon: const Icon(Icons.tag),
                          suffixIcon: entered.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _numberController.clear();
                                    refresh();
                                  },
                                ),
                          border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
                        ),
                        onChanged: (_) => refresh(),
                        onSubmitted: (_) => Navigator.pop(ctx),
                      ),
                      const SizedBox(height: 12),
                      if (_barang.isEmpty)
                        _InfoBox(
                          color: Colors.orange,
                          icon: Icons.info_outline,
                          text: 'Belum ada data Excel. Import file .xlsx (kolom A = NO, kolom B = Nama) agar nama item muncul otomatis.',
                        )
                      else if (entered.isEmpty)
                        _InfoBox(
                          color: Colors.blueGrey,
                          icon: Icons.keyboard_outlined,
                          text: 'Ketik NO, nama item akan muncul otomatis dari Excel (${_barang.length} data).',
                        )
                      else if (matched != null)
                        _InfoBox(color: Colors.green, icon: Icons.check_circle, title: 'NAMA ITEM', text: matched)
                      else
                        _InfoBox(
                          color: Colors.orange,
                          icon: Icons.help_outline,
                          text: 'NO "$entered" tidak ada di Excel. Foto akan diberi nama ${_cleanName(entered)}_FOTO.',
                        ),
                      if (entered.isNotEmpty && _suggestions(entered).length > (matched != null ? 1 : 0)) ...[
                        const SizedBox(height: 8),
                        for (final s in _suggestions(entered))
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              radius: 16,
                              child: Text(s.key.length > 3 ? s.key.substring(0, 3) : s.key, style: const TextStyle(fontSize: 11)),
                            ),
                            title: Text(s.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('NO ${s.key}'),
                            onTap: () {
                              _numberController.text = s.key;
                              _numberController.selection = TextSelection.collapsed(offset: s.key.length);
                              refresh();
                            },
                          ),
                      ],
                      const SizedBox(height: 12),
                      const Text('Format nama file', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final f in AutoFormat.values)
                            ChoiceChip(
                              label: Text(switch (f) {
                                AutoFormat.noName => 'NO_Nama',
                                AutoFormat.nameOnly => 'Nama saja',
                                AutoFormat.noOnly => 'NO saja',
                              }),
                              selected: _autoFormat == f,
                              onSelected: (_) {
                                _autoFormat = f;
                                refresh();
                                _savePreferences();
                              },
                            ),
                        ],
                      ),
                    ] else ...[
                      TextField(
                        controller: _nameController,
                        autofocus: true,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          labelText: 'Nama file sesuai keinginan Anda',
                          prefixIcon: const Icon(Icons.edit_outlined),
                          suffixIcon: _nameController.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _nameController.clear();
                                    refresh();
                                  },
                                ),
                          border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
                        ),
                        onChanged: (_) => refresh(),
                        onSubmitted: (_) => Navigator.pop(ctx),
                      ),
                      const SizedBox(height: 10),
                      const _InfoBox(
                        color: Colors.blueGrey,
                        icon: Icons.info_outline,
                        text: 'Kosongkan untuk nama otomatis berdasarkan tanggal & jam. Nama yang sama akan diberi akhiran _1, _2, dst.',
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'File: ${preview.base}.jpg',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    const Divider(height: 28),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            await _importExcel();
                            if (ctx.mounted) setSheet(() {});
                          },
                          icon: const Icon(Icons.table_view_outlined),
                          label: Text(_barang.isEmpty ? 'Import Excel' : 'Ganti Excel (${_barang.length})'),
                        ),
                        if (_barang.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () async {
                              await _resetDatabase();
                              if (ctx.mounted) setSheet(() {});
                            },
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Hapus data'),
                          ),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showStatus();
                          },
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('Status foto'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                        child: const Text('SELESAI'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await _savePreferences();
    _immersive();
  }

  // ───────────────────────── Sheet: pengaturan ─────────────────────────

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _sheetBg,
      builder: (_) => Theme(
        data: _darkTheme,
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Pengaturan Kamera', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
                const Text('Rasio layar', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final r in CameraRatio.values)
                      ChoiceChip(
                        label: Text(switch (r) {
                          CameraRatio.full => 'Layar penuh',
                          CameraRatio.r4x3 => '4:3',
                          CameraRatio.r16x9 => '16:9',
                          CameraRatio.r1x1 => '1:1',
                        }),
                        selected: _ratio == r,
                        onSelected: (_) {
                          setState(() => _ratio = r);
                          setSheet(() {});
                          _savePreferences();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Kualitas foto', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final q in _qualityOptions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(_qualityKey == q.key ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: _qualityKey == q.key ? _accent : Colors.white54),
                    title: Text(q.title),
                    subtitle: Text(q.subtitle),
                    onTap: () async {
                      if (_qualityKey == q.key) return;
                      setState(() => _qualityKey = q.key);
                      setSheet(() {});
                      await _savePreferences();
                      await _initializeCamera();
                    },
                  ),
                const SizedBox(height: 8),
                const Text('Timer', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final s in const [0, 3, 5, 10])
                      ChoiceChip(
                        label: Text(s == 0 ? 'Mati' : '${s}s'),
                        selected: _timerSeconds == s,
                        onSelected: (_) {
                          setState(() => _timerSeconds = s);
                          setSheet(() {});
                          _savePreferences();
                        },
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Garis bantu (grid)'),
                  value: _gridOn,
                  onChanged: (v) {
                    setState(() => _gridOn = v);
                    setSheet(() {});
                    _savePreferences();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('Status foto'),
                  subtitle: const Text('Item Excel yang sudah / belum difoto'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showStatus();
                  },
                ),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder_outlined),
                  title: Text('Folder penyimpanan'),
                  subtitle: Text('Galeri HP > Pictures > Dokumentasi Barang Pecah'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _savePreferences();
    _immersive();
  }

  // ───────────────────────── UI ─────────────────────────

  Rect _computeViewport(Size size, EdgeInsets pad) {
    if (_ratio == CameraRatio.full) return Offset.zero & size;
    final top = pad.top + 64;
    final w = size.width;
    final h = math.min(w / _portraitRatio(_ratio), size.height - top - 130);
    return Rect.fromLTWH(0, top, w, math.max(h, 100));
  }

  Widget _previewLayer(Rect rect) {
    final cam = _camera;
    final ready = cam != null && cam.value.isInitialized;
    final vp = rect.size;
    return Positioned.fromRect(
      rect: rect,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onTapFocus(d.localPosition, vp),
              onScaleStart: (_) => _baseZoom = _zoom,
              onScaleUpdate: (d) {
                if (d.pointerCount >= 2) _setZoom(_baseZoom * d.scale);
              },
              child: AnimatedOpacity(
                opacity: ready ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: ready ? _coverPreview(cam!) : const SizedBox.expand(),
              ),
            ),
            if (_gridOn) const IgnorePointer(child: CustomPaint(painter: GridPainter(), size: Size.infinite)),
            if (ready) ..._focusWidgets(vp),
          ],
        ),
      ),
    );
  }

  Widget _coverPreview(CameraController cam) {
    final ps = _previewSize(cam);
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        alignment: Alignment.center,
        child: SizedBox(width: ps.width, height: ps.height, child: CameraPreview(cam)),
      ),
    );
  }

  List<Widget> _focusWidgets(Size vp) {
    final fp = _focusPoint;
    if (fp == null) return const [];
    final showSlider = _maxExposure > _minExposure;
    final onRight = fp.dx < vp.width - 110;
    final sliderLeft = onRight ? fp.dx + 46 : fp.dx - 46 - 36;
    final sliderTop = (fp.dy - 70).clamp(0.0, math.max(0.0, vp.height - 140)).toDouble();
    return [
      Positioned(
        left: fp.dx - 34,
        top: fp.dy - 34,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _focusVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: AnimatedScale(
              scale: _focusVisible ? 1 : 1.3,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _accent, width: 1.8),
                ),
              ),
            ),
          ),
        ),
      ),
      if (showSlider)
        Positioned(
          left: sliderLeft,
          top: sliderTop,
          child: IgnorePointer(
            ignoring: !_focusVisible,
            child: AnimatedOpacity(
              opacity: _focusVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: SizedBox(
                width: 36,
                height: 140,
                child: Column(
                  children: [
                    const Icon(Icons.wb_sunny_outlined, color: _accent, size: 18),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: _accent,
                            thumbColor: _accent,
                            inactiveTrackColor: Colors.white38,
                            trackHeight: 2,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: _exposure.clamp(_minExposure, _maxExposure).toDouble(),
                            min: _minExposure,
                            max: _maxExposure,
                            onChanged: _setExposure,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _topBar(EdgeInsets pad) {
    final flashIcon = switch (_flash) {
      FlashSetting.off => Icons.flash_off,
      FlashSetting.auto => Icons.flash_auto,
      FlashSetting.on => Icons.flash_on,
      FlashSetting.torch => Icons.flashlight_on,
    };
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(10, pad.top + 6, 10, 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: .6), Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _TopIcon(icon: flashIcon, active: _flash != FlashSetting.off, onTap: _cycleFlash),
            _TopIcon(
              icon: _timerSeconds == 0 ? Icons.timer_off_outlined : Icons.timer_outlined,
              label: _timerSeconds == 0 ? null : '${_timerSeconds}s',
              active: _timerSeconds > 0,
              onTap: _cycleTimer,
            ),
            _TopIcon(icon: Icons.aspect_ratio, label: _ratioText, onTap: _cycleRatio),
            _TopIcon(
              icon: _gridOn ? Icons.grid_on : Icons.grid_off,
              active: _gridOn,
              onTap: () {
                setState(() => _gridOn = !_gridOn);
                _savePreferences();
              },
            ),
            _TopIcon(icon: Icons.settings_outlined, onTap: _showSettings),
          ],
        ),
      ),
    );
  }

  List<double> get _zoomStops {
    final s = <double>[];
    if (_minZoom < 0.95) s.add((_minZoom * 10).floor() / 10);
    if (_minZoom <= 1.0 && _maxZoom >= 1.0) s.add(1.0);
    if (_maxZoom >= 2) s.add(2.0);
    if (_maxZoom >= 5) s.add(5.0);
    if (_maxZoom >= 10) s.add(10.0);
    return s;
  }

  Widget _zoomPills() {
    final stops = _zoomStops;
    if (stops.length < 2) return const SizedBox.shrink();
    String fmt(double v) => v == v.roundToDouble() ? '${v.toInt()}x' : '${v.toStringAsFixed(1)}x';
    final items = <Widget>[];
    var matchedAny = false;
    for (final z in stops) {
      final selected = (z - _zoom).abs() < 0.06;
      if (selected) matchedAny = true;
      items.add(_ZoomPill(label: fmt(z), selected: selected, onTap: () => _setZoom(z)));
    }
    if (!matchedAny) {
      final idx = stops.indexWhere((z) => z > _zoom);
      items.insert(idx < 0 ? items.length : idx, _ZoomPill(label: fmt(double.parse(_zoom.toStringAsFixed(1))), selected: true, onTap: () {}));
    }
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .4), borderRadius: BorderRadius.circular(22)),
      child: Row(mainAxisSize: MainAxisSize.min, children: items),
    );
  }

  Widget _nameChip() {
    final auto = _naming == NamingMode.auto;
    String text;
    Color color = Colors.white;
    if (auto) {
      final no = _numberController.text.trim();
      if (no.isEmpty) {
        text = _barang.isEmpty ? 'Ketuk: isi NO / import Excel' : 'Ketuk & ketik NO barang';
        color = Colors.white70;
      } else {
        final m = _findBarang(no);
        text = m != null ? '$no · $m' : '$no · tidak ada di Excel';
        if (m == null) color = _accent;
      }
    } else {
      final n = _nameController.text.trim();
      text = n.isEmpty ? 'Ketuk: isi nama manual' : n;
      if (n.isEmpty) color = Colors.white70;
    }
    return GestureDetector(
      onTap: _showNameSheet,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(color: auto ? const Color(0xFF1E6FE8) : Colors.white24, borderRadius: BorderRadius.circular(18)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(auto ? Icons.auto_awesome : Icons.edit, size: 13, color: Colors.white),
                const SizedBox(width: 4),
                Text(auto ? 'AUTO' : 'MANUAL', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _shutterButton() {
    return GestureDetector(
      onTap: _takePhoto,
      child: SizedBox(
        width: 82,
        height: 82,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 82,
              height: 82,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: _capturing ? 52 : 64,
              height: _capturing ? 52 : 64,
              decoration: BoxDecoration(color: _capturing ? Colors.white70 : Colors.white, shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _galleryButton() {
    return GestureDetector(
      onTap: _showGallery,
      child: SizedBox(
        width: 58,
        height: 58,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 54,
              height: 54,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white, width: 2),
                color: Colors.white12,
              ),
              child: _latestPhoto != null
                  ? Image.file(File(_latestPhoto!), fit: BoxFit.cover, cacheWidth: 160, errorBuilder: (_, __, ___) => const Icon(Icons.photo_library_outlined, color: Colors.white))
                  : const Icon(Icons.photo_library_outlined, color: Colors.white),
            ),
            if (_savingCount > 0)
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(14)),
                child: const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))),
              ),
            if (_photos.isNotEmpty && _savingCount == 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: const Color(0xFF1E6FE8), borderRadius: BorderRadius.circular(10)),
                  child: Text('${_photos.length}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomControls(EdgeInsets pad) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(22, 40, 22, math.max(pad.bottom, 12) + 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: .72)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _zoomPills(),
            const SizedBox(height: 12),
            _nameChip(),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: Align(alignment: Alignment.centerLeft, child: _galleryButton())),
                _shutterButton(),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: _switchCamera,
                      child: Container(
                        width: 54,
                        height: 54,
                        decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                        child: const Icon(Icons.flip_camera_android_outlined, color: Colors.white, size: 26),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionView() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 64),
          const SizedBox(height: 16),
          const Text('Izin kamera diperlukan', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('Aktifkan izin Kamera untuk Cam Dat di pengaturan HP.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 20),
          FilledButton(onPressed: openAppSettings, child: const Text('BUKA PENGATURAN')),
          TextButton(onPressed: _start, child: const Text('Coba lagi')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final pad = mq.viewPadding;
    final viewport = _computeViewport(size, pad);
    _viewportRatio = viewport.width / viewport.height;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: _permissionDenied
            ? _permissionView()
            : Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  _previewLayer(viewport),
                  _topBar(pad),
                  _bottomControls(pad),
                  if (_countdown > 0)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Text('$_countdown',
                              style: const TextStyle(color: Colors.white, fontSize: 120, fontWeight: FontWeight.w300, shadows: [Shadow(blurRadius: 16, color: Colors.black54)])),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _shutterFlash ? .75 : 0,
                        duration: const Duration(milliseconds: 90),
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),
                  ),
                  if (_initializing && _slowInit)
                    const Center(child: CircularProgressIndicator(color: Colors.white54)),
                ],
              ),
      ),
    );
  }
}

class _TopIcon extends StatelessWidget {
  final IconData icon;
  final String? label;
  final bool active;
  final VoidCallback onTap;
  const _TopIcon({required this.icon, required this.onTap, this.label, this.active = false});
  @override
  Widget build(BuildContext context) {
    final color = active ? _accent : Colors.white;
    const shadow = [Shadow(blurRadius: 6, color: Colors.black54)];
    return InkResponse(
      onTap: onTap,
      radius: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 25, shadows: shadow),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(label!, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w800, shadows: shadow)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ZoomPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ZoomPill({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: selected ? 46 : 38,
        height: selected ? 38 : 32,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? Colors.black54 : Colors.transparent, shape: BoxShape.circle),
        child: Text(label, style: TextStyle(color: selected ? _accent : Colors.white, fontSize: selected ? 13 : 12, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String? title;
  final String text;
  const _InfoBox({required this.color, required this.icon, required this.text, this.title});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) Text(title!, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .6)),
                Text(text, style: TextStyle(fontSize: title != null ? 19 : 13.5, fontWeight: title != null ? FontWeight.w700 : FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class GridPainter extends CustomPainter {
  const GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: .35)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), p);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), p);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), p);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PhotoStatusPage extends StatelessWidget {
  final Map<String, String> barang;
  final Map<String, List<String>> history;
  const PhotoStatusPage({super.key, required this.barang, required this.history});

  @override
  Widget build(BuildContext context) {
    final keys = barang.keys.toList();
    var done = 0;
    for (final k in keys) { if ((history[k.isEmpty ? k : k.replaceFirst(RegExp(r'^0+'), '').isEmpty ? '0' : k.replaceFirst(RegExp(r'^0+'), '')] ?? const []).isNotEmpty) done++; }
    final pending = keys.length - done;
    return Scaffold(
      appBar: AppBar(title: const Text('STATUS FOTO')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          Expanded(child: _StatusCard(title: 'TOTAL', value: '${keys.length}', icon: Icons.inventory_2_outlined)),
          const SizedBox(width: 8),
          Expanded(child: _StatusCard(title: 'SUDAH', value: '$done', icon: Icons.check_circle_outline)),
          const SizedBox(width: 8),
          Expanded(child: _StatusCard(title: 'BELUM', value: '$pending', icon: Icons.pending_outlined)),
        ])),
        Expanded(child: keys.isEmpty ? const Center(child: Text('Import Excel terlebih dahulu.')) : ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          itemCount: keys.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final no = keys[i];
            final normalizedNo = no.replaceFirst(RegExp(r'^0+'), '').isEmpty ? '0' : no.replaceFirst(RegExp(r'^0+'), '');
            final count = (history[normalizedNo] ?? const []).length;
            final doneItem = count > 0;
            return Card(child: ListTile(
              leading: CircleAvatar(child: Icon(doneItem ? Icons.check : Icons.hourglass_empty)),
              title: Text(no, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(barang[no] ?? 'Barang'),
              trailing: Text(doneItem ? 'SUDAH DIFOTO\n$count FOTO' : 'BELUM DIFOTO', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: doneItem ? Colors.green : Colors.orange)),
            ));
          },
        )),
      ]),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title, value;
  final IconData icon;
  const _StatusCard({required this.title, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [Icon(icon), const SizedBox(height: 4), Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)), Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))])));
}

class PhotoGalleryPage extends StatefulWidget {
  final List<File> photos;
  final Future<void> Function() onChanged;
  const PhotoGalleryPage({super.key, required this.photos, required this.onChanged});
  @override
  State<PhotoGalleryPage> createState() => _PhotoGalleryPageState();
}

class _PhotoGalleryPageState extends State<PhotoGalleryPage> {
  late List<File> photos;
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    photos = [...widget.photos];
  }

  bool get _allSelected => photos.isNotEmpty && _selected.length == photos.length;

  void _toggle(File f) {
    setState(() {
      if (!_selected.remove(f.path)) _selected.add(f.path);
    });
  }

  void _startSelecting(File f) {
    setState(() {
      _selecting = true;
      _selected.add(f.path);
    });
  }

  void _exitSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(photos.map((f) => f.path));
      }
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _deleteOne(File file) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus foto?'),
        content: Text(file.path.split('/').last),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('HAPUS')),
        ],
      ),
    );
    if (yes != true) return;
    final name = file.path.split('/').last;
    try {
      await file.delete();
    } catch (_) {}
    await _deleteGalleryCopies([name]);
    if (mounted) setState(() => photos.removeWhere((f) => f.path == file.path));
    await widget.onChanged();
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    if (count == 0 || _busy) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus $count foto?'),
        content: const Text('Foto juga akan dihapus dari Galeri HP dan tidak bisa dikembalikan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('HAPUS')),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    final names = <String>[];
    for (final path in _selected.toList()) {
      try {
        await File(path).delete();
        names.add(path.split('/').last);
      } catch (_) {}
    }
    await _deleteGalleryCopies(names);
    if (!mounted) return;
    setState(() {
      photos.removeWhere((f) => _selected.contains(f.path));
      _selected.clear();
      _selecting = false;
      _busy = false;
    });
    await widget.onChanged();
    _toast('${names.length} foto dihapus.');
  }

  Future<void> _shareSelected() async {
    if (_selected.isEmpty || _busy) return;
    final paths = photos.where((f) => _selected.contains(f.path)).map((f) => f.path).toList();
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Bagikan ${paths.length} foto', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Kirim foto langsung'),
              subtitle: const Text('Foto dikirim apa adanya (WhatsApp, Drive, dll.)'),
              onTap: () => Navigator.pop(ctx, 'direct'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: const Text('Kompres ke ZIP dulu'),
              subtitle: const Text('Semua foto dijadikan satu file .zip'),
              onTap: () => Navigator.pop(ctx, 'zip'),
            ),
          ],
        ),
      ),
    );
    if (mode == null) return;
    setState(() => _busy = true);
    try {
      if (mode == 'zip') {
        final zip = await _zipFilesNative(paths, _zipTimestampName());
        if (zip == null) throw Exception('ZIP gagal dibuat');
        await _shareFilesNative([zip], 'application/zip');
      } else {
        await _shareFilesNative(paths, 'image/*');
      }
    } catch (e) {
      _toast('Gagal membagikan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tile(File file) {
    final selected = _selected.contains(file.path);
    return GestureDetector(
      onTap: () {
        if (_selecting) {
          _toggle(file);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PhotoViewerPage(file: file, onDelete: () => _deleteOne(file))),
          );
        }
      },
      onLongPress: () => _selecting ? _toggle(file) : _startSelecting(file),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(file, fit: BoxFit.cover, cacheWidth: 300),
          if (_selecting)
            Container(
              decoration: BoxDecoration(
                color: selected ? Colors.blue.withValues(alpha: .28) : Colors.transparent,
                border: selected ? Border.all(color: Colors.blue, width: 3) : null,
              ),
            ),
          if (_selecting)
            Positioned(
              left: 6,
              top: 6,
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? Colors.blue : Colors.white,
                size: 24,
                shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelecting();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelecting) : null,
          title: Text(_selecting ? '${_selected.length} dipilih' : 'Galeri (${photos.length})'),
          actions: _selecting
              ? [
                  TextButton.icon(
                    onPressed: photos.isEmpty ? null : _toggleAll,
                    icon: Icon(_allSelected ? Icons.deselect : Icons.select_all),
                    label: Text(_allSelected ? 'Batal semua' : 'Pilih semua'),
                  ),
                ]
              : [
                  if (photos.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() => _selecting = true),
                      icon: const Icon(Icons.checklist),
                      label: const Text('Pilih'),
                    ),
                  IconButton(onPressed: () async { await widget.onChanged(); }, icon: const Icon(Icons.refresh)),
                ],
        ),
        body: Stack(
          children: [
            photos.isEmpty
                ? const Center(child: Text('Belum ada foto.'))
                : GridView.builder(
                    padding: const EdgeInsets.all(6),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
                    itemCount: photos.length,
                    itemBuilder: (_, i) => _tile(photos[i]),
                  ),
            if (_busy)
              const Positioned.fill(
                child: ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator())),
              ),
          ],
        ),
        bottomNavigationBar: _selecting
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _selected.isEmpty || _busy ? null : _deleteSelected,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('HAPUS'),
                          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: Colors.red),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _selected.isEmpty || _busy ? null : _shareSelected,
                          icon: const Icon(Icons.share),
                          label: const Text('BAGIKAN'),
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

class PhotoViewerPage extends StatelessWidget {
  final File file;
  final Future<void> Function() onDelete;
  const PhotoViewerPage({super.key, required this.file, required this.onDelete});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Foto')),
    body: Column(children: [
      Expanded(child: InteractiveViewer(child: Center(child: Image.file(file)))),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: FilledButton.icon(onPressed: () async { final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PhotoEditorPage(file: file))); if (changed == true && context.mounted) Navigator.pop(context); }, icon: const Icon(Icons.edit), label: const Text('EDIT'))),
        const SizedBox(width: 10),
        IconButton.filled(onPressed: () async { try { await _shareFilesNative([file.path], 'image/*'); } catch (_) {} }, icon: const Icon(Icons.share)),
        const SizedBox(width: 6),
        IconButton.filled(onPressed: () async { await onDelete(); if (context.mounted) Navigator.pop(context); }, icon: const Icon(Icons.delete_outline)),
      ]))),
    ]),
  );
}

enum EditTool { effect, adjust, erase, crop, transform, annotate }
enum EditorEffect { natural, vivid, warm, cool, mono, document }
enum EraseMode { auto, manual }
enum AnnotationMode { circle, rectangle, arrow, text, number }

class PhotoEditorPage extends StatefulWidget {
  final File file;
  const PhotoEditorPage({super.key, required this.file});
  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  img.Image? _image;
  Uint8List? _previewBytes;
  final List<Uint8List> _undo = [];
  final List<Uint8List> _redo = [];
  final List<_EditorMark> _marks = [];
  final List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];
  EditTool _tool = EditTool.effect;
  EditorEffect _effect = EditorEffect.natural;
  EraseMode _eraseMode = EraseMode.auto;
  AnnotationMode _annotationMode = AnnotationMode.circle;
  double _brush = 42;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  double _temperature = 0;
  double _sharpness = 0;
  double _highlights = 0;
  double _shadows = 0;
  double _cropStartX = .12;
  double _cropStartY = .12;
  double _cropEndX = .88;
  double _cropEndY = .88;
  Offset? _cropAnchor;
  Offset? _autoErasePoint;
  int _numberMarker = 1;
  bool _busy = false;
  bool _showBefore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Format foto tidak dapat dibaca');
      if (!mounted) return;
      setState(() {
        _image = decoded;
        _previewBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 94));
      });
    } catch (e) {
      if (mounted) _message('Gagal membuka foto: $e');
    }
  }

  Future<void> _pushHistory() async {
    final image = _image;
    if (image == null) return;
    _undo.add(Uint8List.fromList(img.encodeJpg(image, quality: 92)));
    if (_undo.length > 8) _undo.removeAt(0);
    _redo.clear();
  }

  Future<void> _refreshPreview() async {
    final image = _image;
    if (image == null || !mounted) return;
    setState(() {
      _previewBytes = Uint8List.fromList(img.encodeJpg(image, quality: 94));
    });
  }

  Future<void> _undoEdit() async {
    if (_undo.isEmpty) return;
    final image = _image;
    if (image == null) return;
    _redo.add(Uint8List.fromList(img.encodeJpg(image, quality: 92)));
    final bytes = _undo.removeLast();
    final restored = img.decodeImage(bytes);
    if (restored == null) return;
    setState(() {
      _image = restored;
      _strokes.clear();
      _marks.clear();
      _autoErasePoint = null;
    });
    await _refreshPreview();
  }

  Future<void> _redoEdit() async {
    if (_redo.isEmpty) return;
    final image = _image;
    if (image == null) return;
    _undo.add(Uint8List.fromList(img.encodeJpg(image, quality: 92)));
    final bytes = _redo.removeLast();
    final restored = img.decodeImage(bytes);
    if (restored == null) return;
    setState(() => _image = restored);
    await _refreshPreview();
  }

  Future<void> _resetAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset semua edit?'),
        content: const Text('Foto akan kembali ke kondisi asli.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('RESET')),
        ],
      ),
    );
    if (yes != true) return;
    final bytes = await widget.file.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return;
    _undo.clear();
    _redo.clear();
    _marks.clear();
    _strokes.clear();
    setState(() {
      _image = original;
      _effect = EditorEffect.natural;
      _brightness = 0;
      _contrast = 0;
      _saturation = 0;
      _temperature = 0;
      _sharpness = 0;
      _highlights = 0;
      _shadows = 0;
    });
    await _refreshPreview();
  }

  Future<void> _applyEffect(EditorEffect effect) async {
    final source = _image;
    if (source == null || _busy) return;
    await _pushHistory();
    setState(() {
      _busy = true;
      _effect = effect;
    });
    try {
      final out = img.Image.from(source);
      for (final pixel in out) {
        var r = pixel.r.toDouble();
        var g = pixel.g.toDouble();
        var b = pixel.b.toDouble();
        final avg = (r + g + b) / 3;
        switch (effect) {
          case EditorEffect.natural:
            break;
          case EditorEffect.vivid:
            r = avg + (r - avg) * 1.28;
            g = avg + (g - avg) * 1.28;
            b = avg + (b - avg) * 1.28;
            r = (r - 128) * 1.08 + 128;
            g = (g - 128) * 1.08 + 128;
            b = (b - 128) * 1.08 + 128;
            break;
          case EditorEffect.warm:
            r += 16;
            g += 5;
            b -= 12;
            break;
          case EditorEffect.cool:
            r -= 12;
            g += 2;
            b += 16;
            break;
          case EditorEffect.mono:
            r = g = b = .299 * r + .587 * g + .114 * b;
            break;
          case EditorEffect.document:
            r = g = b = .299 * r + .587 * g + .114 * b;
            r = g = b = (r - 128) * 1.45 + 128;
            break;
        }
        pixel.r = r.clamp(0, 255).round();
        pixel.g = g.clamp(0, 255).round();
        pixel.b = b.clamp(0, 255).round();
      }
      setState(() => _image = out);
      await _refreshPreview();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyAdjustments() async {
    final source = _image;
    if (source == null || _busy) return;
    if (_brightness == 0 && _contrast == 0 && _saturation == 0 && _temperature == 0 && _sharpness == 0 && _highlights == 0 && _shadows == 0) return;
    await _pushHistory();
    setState(() => _busy = true);
    try {
      var out = img.Image.from(source);
      final br = _brightness * 1.6;
      final ct = 1 + (_contrast / 100);
      final sat = 1 + (_saturation / 100);
      final temp = _temperature * 0.55;
      for (final pixel in out) {
        var r = pixel.r.toDouble();
        var g = pixel.g.toDouble();
        var b = pixel.b.toDouble();
        final lum = .299 * r + .587 * g + .114 * b;
        final shadowWeight = (1 - lum / 255).clamp(0.0, 1.0);
        final highlightWeight = (lum / 255).clamp(0.0, 1.0);
        r += br + (_shadows * shadowWeight) + (_highlights * highlightWeight);
        g += br + (_shadows * shadowWeight) + (_highlights * highlightWeight);
        b += br + (_shadows * shadowWeight) + (_highlights * highlightWeight);
        r = (r - 128) * ct + 128;
        g = (g - 128) * ct + 128;
        b = (b - 128) * ct + 128;
        final avg = (r + g + b) / 3;
        r = avg + (r - avg) * sat;
        g = avg + (g - avg) * sat;
        b = avg + (b - avg) * sat;
        r += temp;
        b -= temp;
        pixel.r = r.clamp(0, 255).round();
        pixel.g = g.clamp(0, 255).round();
        pixel.b = b.clamp(0, 255).round();
      }
      if (_sharpness > 0) {
        out = img.convolution(out, filter: [
          0, -1, 0,
          -1, 5 + (_sharpness / 25), -1,
          0, -1, 0,
        ]);
      }
      setState(() => _image = out);
      await _refreshPreview();
      setState(() {
        _brightness = 0;
        _contrast = 0;
        _saturation = 0;
        _temperature = 0;
        _sharpness = 0;
        _highlights = 0;
        _shadows = 0;
      });
      _message('Penyesuaian diterapkan.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotate(int turns) async {
    final source = _image;
    if (source == null) return;
    await _pushHistory();
    var out = source;
    for (var i = 0; i < turns.abs(); i++) {
      out = turns > 0 ? img.copyRotate(out, angle: 90) : img.copyRotate(out, angle: -90);
    }
    setState(() => _image = out);
    await _refreshPreview();
  }

  Future<void> _flip(bool horizontal) async {
    final source = _image;
    if (source == null) return;
    await _pushHistory();
    final out = img.flip(source, direction: horizontal ? img.FlipDirection.horizontal : img.FlipDirection.vertical);
    setState(() => _image = out);
    await _refreshPreview();
  }

  Rect _imageRect(Size canvas) {
    final image = _image;
    if (image == null || image.width == 0 || image.height == 0) return Offset.zero & canvas;
    final scale = math.min(canvas.width / image.width, canvas.height / image.height);
    final w = image.width * scale;
    final h = image.height * scale;
    return Rect.fromLTWH((canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
  }

  Offset _toNormalized(Offset p, Size canvas) {
    final rect = _imageRect(canvas);
    return Offset(
      ((p.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((p.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
  }

  Offset _toImagePoint(Offset normalized, img.Image image) => Offset(
        normalized.dx * (image.width - 1),
        normalized.dy * (image.height - 1),
      );

  Future<void> _autoEraseAt(Offset normalized) async {
    final source = _image;
    if (source == null || _busy) return;
    await _pushHistory();
    setState(() {
      _busy = true;
      _autoErasePoint = normalized;
    });
    try {
      final maxSide = 720;
      final scale = math.min(1.0, maxSide / math.max(source.width, source.height));
      final small = scale < 1 ? img.copyResize(source, width: (source.width * scale).round(), height: (source.height * scale).round()) : img.Image.from(source);
      final sx = (normalized.dx * (small.width - 1)).round().clamp(0, small.width - 1);
      final sy = (normalized.dy * (small.height - 1)).round().clamp(0, small.height - 1);
      final seed = small.getPixel(sx, sy);
      final mask = List<bool>.filled(small.width * small.height, false);
      final queue = <int>[sy * small.width + sx];
      mask[sy * small.width + sx] = true;
      final threshold = 34.0;
      var head = 0;
      var minX = sx, maxX = sx, minY = sy, maxY = sy;
      while (head < queue.length && queue.length < small.width * small.height * .28) {
        final index = queue[head++];
        final x = index % small.width;
        final y = index ~/ small.width;
        minX = math.min(minX, x); maxX = math.max(maxX, x); minY = math.min(minY, y); maxY = math.max(maxY, y);
        for (final n in const [
          [-1, 0], [1, 0], [0, -1], [0, 1]
        ]) {
          final nx = x + n[0], ny = y + n[1];
          if (nx < 0 || ny < 0 || nx >= small.width || ny >= small.height) continue;
          final ni = ny * small.width + nx;
          if (mask[ni]) continue;
          final c = small.getPixel(nx, ny);
          final d = math.sqrt(math.pow(c.r - seed.r, 2) + math.pow(c.g - seed.g, 2) + math.pow(c.b - seed.b, 2));
          if (d <= threshold) {
            mask[ni] = true;
            queue.add(ni);
          }
        }
      }
      if (queue.length < 12) {
        _message('Objek otomatis tidak cukup jelas. Gunakan MANUAL ERASER.');
        return;
      }
      final out = img.Image.from(source);
      final fullMinX = math.max(0, (minX / small.width * source.width).floor() - 3);
      final fullMaxX = math.min(source.width - 1, ((maxX + 1) / small.width * source.width).ceil() + 3);
      final fullMinY = math.max(0, (minY / small.height * source.height).floor() - 3);
      final fullMaxY = math.min(source.height - 1, ((maxY + 1) / small.height * source.height).ceil() + 3);
      _inpaintMask(out, source, (x, y) {
        final mx = (x / source.width * small.width).floor().clamp(0, small.width - 1);
        final my = (y / source.height * small.height).floor().clamp(0, small.height - 1);
        return mask[my * small.width + mx];
      }, fullMinX, fullMaxX, fullMinY, fullMaxY);
      setState(() => _image = out);
      await _refreshPreview();
      _message('Objek otomatis dihapus.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _inpaintMask(img.Image out, img.Image source, bool Function(int, int) isMasked, int minX, int maxX, int minY, int maxY) {
    final work = img.Image.from(source);
    final maxPass = math.max(8, math.min(28, ((maxX - minX + maxY - minY) / 20).round()));
    for (var pass = 0; pass < maxPass; pass++) {
      var changed = 0;
      for (var y = minY; y <= maxY; y++) {
        for (var x = minX; x <= maxX; x++) {
          if (!isMasked(x, y)) continue;
          final neighbors = <img.Color>[];
          for (final d in const [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
            final nx = x + d[0], ny = y + d[1];
            if (nx < 0 || ny < 0 || nx >= source.width || ny >= source.height) continue;
            if (!isMasked(nx, ny)) neighbors.add(work.getPixel(nx, ny));
          }
          if (neighbors.isEmpty) continue;
          var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
          for (final c in neighbors) { r += c.r; g += c.g; b += c.b; a += c.a; }
          work.setPixel(x, y, img.ColorRgba8((r / neighbors.length).round(), (g / neighbors.length).round(), (b / neighbors.length).round(), (a / neighbors.length).round()));
          changed++;
        }
      }
      if (changed == 0) break;
    }
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        if (isMasked(x, y)) out.setPixel(x, y, work.getPixel(x, y));
      }
    }
  }

  void _addManualStroke(Offset normalized) {
    _currentStroke = [normalized];
  }

  void _continueManualStroke(Offset normalized) {
    if (_currentStroke.isEmpty) return;
    setState(() => _currentStroke.add(normalized));
  }

  void _finishManualStroke() {
    if (_currentStroke.isEmpty) return;
    setState(() {
      _strokes.add([..._currentStroke]);
      _currentStroke = [];
    });
  }

  Future<void> _applyManualErase() async {
    final source = _image;
    if (source == null || _strokes.isEmpty || _busy) return;
    await _pushHistory();
    setState(() => _busy = true);
    try {
      final out = img.Image.from(source);
      for (final stroke in _strokes) {
        for (final point in stroke) {
          final p = _toImagePoint(point, source);
          final radius = (_brush * source.width / 420).round().clamp(6, 180).toInt();
          _softErase(out, source, p.dx.round(), p.dy.round(), radius);
        }
      }
      setState(() {
        _image = out;
        _strokes.clear();
      });
      await _refreshPreview();
      _message('Area manual berhasil dihapus.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _softErase(img.Image out, img.Image src, int cx, int cy, int radius) {
    final ring = math.max(3, radius ~/ 2);
    final samples = <img.Color>[];
    for (var dy = -radius; dy <= radius; dy += math.max(2, radius ~/ 4)) {
      for (var dx = -radius; dx <= radius; dx += math.max(2, radius ~/ 4)) {
        final d = math.sqrt(dx * dx + dy * dy);
        if (d >= ring && d <= radius + 2) {
          samples.add(src.getPixel((cx + dx).clamp(0, src.width - 1), (cy + dy).clamp(0, src.height - 1)));
        }
      }
    }
    if (samples.isEmpty) return;
    var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    for (final c in samples) { r += c.r; g += c.g; b += c.b; a += c.a; }
    final fill = img.ColorRgba8((r / samples.length).round(), (g / samples.length).round(), (b / samples.length).round(), (a / samples.length).round());
    for (var y = math.max(0, cy - radius); y <= math.min(out.height - 1, cy + radius); y++) {
      for (var x = math.max(0, cx - radius); x <= math.min(out.width - 1, cx + radius); x++) {
        final d = math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2));
        if (d <= radius) {
          final alpha = (1 - d / radius).clamp(0.0, 1.0);
          final old = out.getPixel(x, y);
          out.setPixel(x, y, img.ColorRgba8(
            (old.r * (1 - alpha) + fill.r * alpha).round(),
            (old.g * (1 - alpha) + fill.g * alpha).round(),
            (old.b * (1 - alpha) + fill.b * alpha).round(),
            old.a.toInt(),
          ));
        }
      }
    }
  }

  Future<void> _applyCrop() async {
    final source = _image;
    if (source == null) return;
    final left = math.min(_cropStartX, _cropEndX).clamp(0.0, 1.0);
    final right = math.max(_cropStartX, _cropEndX).clamp(0.0, 1.0);
    final top = math.min(_cropStartY, _cropEndY).clamp(0.0, 1.0);
    final bottom = math.max(_cropStartY, _cropEndY).clamp(0.0, 1.0);
    final x = (left * source.width).round();
    final y = (top * source.height).round();
    final w = math.max(1, ((right - left) * source.width).round());
    final h = math.max(1, ((bottom - top) * source.height).round());
    await _pushHistory();
    final out = img.copyCrop(source, x: x.clamp(0, source.width - 1), y: y.clamp(0, source.height - 1), width: math.min(w, source.width - x), height: math.min(h, source.height - y));
    setState(() => _image = out);
    await _refreshPreview();
    _cropStartX = .12; _cropStartY = .12; _cropEndX = .88; _cropEndY = .88;
  }

  Future<void> _addTextMark(Offset normalized) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Tambahkan teks'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Contoh: RETAK / PECAH / PENYOK')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('BATAL')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('TAMBAH'))],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    setState(() => _marks.add(_EditorMark(mode: AnnotationMode.text, start: normalized, end: normalized, text: text)));
  }

  Future<void> _saveEdited() async {
    final image = _image;
    if (image == null || _busy) return;
    setState(() => _busy = true);
    try {
      final out = img.Image.from(image);
      for (final mark in _marks) {
        _drawMark(out, mark);
      }
      final bytes = img.encodeJpg(out, quality: 95);
      var target = File(widget.file.path.replaceFirst(RegExp(r'\.[^.]+$'), '_EDIT.jpg'));
      var n = 1;
      while (await target.exists()) {
        target = File(widget.file.path.replaceFirst(RegExp(r'\.[^.]+$'), '_EDIT_$n.jpg'));
        n++;
      }
      await target.writeAsBytes(bytes, flush: true);
      if (Platform.isAndroid) {
        try {
          await const MethodChannel('dokumentasi_barang_pecah/media_store').invokeMethod('saveImage', <String, dynamic>{
            'bytes': bytes,
            'displayName': target.path.split(Platform.pathSeparator).last,
            'relativePath': 'Pictures/Dokumentasi Barang Pecah',
          });
        } on PlatformException {
          // Salinan lokal tetap tersedia.
        }
      }
      if (mounted) {
        _message('Foto hasil edit berhasil disimpan ke Gallery.');
        Navigator.pop(context, true);
      }
    } catch (e) {
      _message('Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _drawCircleOutline(img.Image image, int cx, int cy, int radius, img.Color color, int thickness) {
    final outer = radius;
    final inner = math.max(0, radius - math.max(1, thickness));
    final minX = math.max(0, cx - outer);
    final maxX = math.min(image.width - 1, cx + outer);
    final minY = math.max(0, cy - outer);
    final maxY = math.min(image.height - 1, cy + outer);
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final d = math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2));
        if (d <= outer && d >= inner) image.setPixel(x, y, color);
      }
    }
  }

  void _drawMark(img.Image image, _EditorMark mark) {
    final sx = (mark.start.dx * image.width).round();
    final sy = (mark.start.dy * image.height).round();
    final ex = (mark.end.dx * image.width).round();
    final ey = (mark.end.dy * image.height).round();
    final color = img.ColorRgb8(255, 50, 50);
    final thickness = math.max(4, image.width ~/ 420);
    switch (mark.mode) {
      case AnnotationMode.circle:
        final cx = ((sx + ex) / 2).round();
        final cy = ((sy + ey) / 2).round();
        final radius = (math.max((ex - sx).abs(), (ey - sy).abs()) / 2).round();
        _drawCircleOutline(image, cx, cy, math.max(8, radius), color, thickness);
        break;
      case AnnotationMode.rectangle:
        img.drawRect(image, x1: math.min(sx, ex), y1: math.min(sy, ey), x2: math.max(sx, ex), y2: math.max(sy, ey), color: color, thickness: thickness);
        break;
      case AnnotationMode.arrow:
        img.drawLine(image, x1: sx, y1: sy, x2: ex, y2: ey, color: color, thickness: thickness);
        final angle = math.atan2(ey - sy, ex - sx);
        final len = math.max(18, image.width ~/ 28).toDouble();
        final a1 = angle + math.pi * .83;
        final a2 = angle - math.pi * .83;
        img.drawLine(image, x1: ex, y1: ey, x2: (ex + len * math.cos(a1)).round(), y2: (ey + len * math.sin(a1)).round(), color: color, thickness: thickness);
        img.drawLine(image, x1: ex, y1: ey, x2: (ex + len * math.cos(a2)).round(), y2: (ey + len * math.sin(a2)).round(), color: color, thickness: thickness);
        break;
      case AnnotationMode.text:
        img.drawString(image, mark.text ?? '', font: img.arial24, x: sx, y: sy, color: color);
        break;
      case AnnotationMode.number:
        _drawCircleOutline(image, sx, sy, math.max(22, image.width ~/ 70), color, thickness);
        img.drawString(image, mark.text ?? '1', font: img.arial24, x: sx - 7, y: sy - 12, color: img.ColorRgb8(255, 255, 255));
        break;
    }
  }

  void _message(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(s)));
  }

  String _effectName(EditorEffect e) => switch (e) {
        EditorEffect.natural => 'Natural',
        EditorEffect.vivid => 'Vivid',
        EditorEffect.warm => 'Warm',
        EditorEffect.cool => 'Cool',
        EditorEffect.mono => 'B&W',
        EditorEffect.document => 'Document',
      };

  String _toolName(EditTool t) => switch (t) {
        EditTool.effect => 'Effect',
        EditTool.adjust => 'Adjust',
        EditTool.erase => 'Eraser',
        EditTool.crop => 'Crop',
        EditTool.transform => 'Rotate / Flip',
        EditTool.annotate => 'Marking',
      };

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('EDIT FOTO', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip: 'Undo', onPressed: _undo.isEmpty || _busy ? null : _undoEdit, icon: const Icon(Icons.undo)),
          IconButton(tooltip: 'Redo', onPressed: _redo.isEmpty || _busy ? null : _redoEdit, icon: const Icon(Icons.redo)),
          IconButton(tooltip: 'Reset', onPressed: _busy ? null : _resetAll, icon: const Icon(Icons.restart_alt)),
          IconButton(tooltip: 'Simpan', onPressed: _busy ? null : _saveEdited, icon: const Icon(Icons.save_outlined)),
        ],
      ),
      body: image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      return GestureDetector(
                        onTapDown: _tool == EditTool.erase && _eraseMode == EraseMode.auto
                            ? (d) => _autoEraseAt(_toNormalized(d.localPosition, c.biggest))
                            : _tool == EditTool.annotate && _annotationMode == AnnotationMode.text
                                ? (d) => _addTextMark(_toNormalized(d.localPosition, c.biggest))
                                : _tool == EditTool.annotate && _annotationMode == AnnotationMode.number
                                    ? (d) => setState(() => _marks.add(_EditorMark(mode: AnnotationMode.number, start: _toNormalized(d.localPosition, c.biggest), end: _toNormalized(d.localPosition, c.biggest), text: '${_numberMarker++}')))
                                    : null,
                        onPanStart: _tool == EditTool.erase && _eraseMode == EraseMode.manual
                            ? (d) => _addManualStroke(_toNormalized(d.localPosition, c.biggest))
                            : _tool == EditTool.crop
                                ? (d) {
                                    final n = _toNormalized(d.localPosition, c.biggest);
                                    setState(() { _cropAnchor = n; _cropStartX = n.dx; _cropStartY = n.dy; _cropEndX = n.dx; _cropEndY = n.dy; });
                                  }
                                : _tool == EditTool.annotate && (_annotationMode == AnnotationMode.circle || _annotationMode == AnnotationMode.rectangle || _annotationMode == AnnotationMode.arrow)
                                    ? (d) {
                                        final n = _toNormalized(d.localPosition, c.biggest);
                                        setState(() => _marks.add(_EditorMark(mode: _annotationMode, start: n, end: n)));
                                      }
                                    : null,
                        onPanUpdate: _tool == EditTool.erase && _eraseMode == EraseMode.manual
                            ? (d) => _continueManualStroke(_toNormalized(d.localPosition, c.biggest))
                            : _tool == EditTool.crop && _cropAnchor != null
                                ? (d) {
                                    final n = _toNormalized(d.localPosition, c.biggest);
                                    setState(() { _cropEndX = n.dx; _cropEndY = n.dy; });
                                  }
                                : _tool == EditTool.annotate && _marks.isNotEmpty && (_annotationMode == AnnotationMode.circle || _annotationMode == AnnotationMode.rectangle || _annotationMode == AnnotationMode.arrow)
                                    ? (d) {
                                        final n = _toNormalized(d.localPosition, c.biggest);
                                        setState(() => _marks[_marks.length - 1] = _marks.last.copyWith(end: n));
                                      }
                                    : null,
                        onPanEnd: _tool == EditTool.erase && _eraseMode == EraseMode.manual
                            ? (_) => _finishManualStroke()
                            : _tool == EditTool.crop
                                ? (_) => setState(() => _cropAnchor = null)
                                : null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Center(
                              child: _showBefore ? Image.file(widget.file, fit: BoxFit.contain) : (_previewBytes == null ? const SizedBox() : Image.memory(_previewBytes!, fit: BoxFit.contain, gaplessPlayback: true)),
                            ),
                            if (_tool == EditTool.erase && _eraseMode == EraseMode.manual)
                              CustomPaint(painter: _EditorStrokePainter(_strokes, _currentStroke, _brush), size: Size.infinite),
                            if (_tool == EditTool.erase && _eraseMode == EraseMode.auto && _autoErasePoint != null)
                              CustomPaint(painter: _AutoPointPainter(_autoErasePoint!), size: Size.infinite),
                            if (_tool == EditTool.crop)
                              CustomPaint(painter: _CropPainter(_cropStartX, _cropStartY, _cropEndX, _cropEndY), size: Size.infinite),
                            if (_tool == EditTool.annotate)
                              CustomPaint(painter: _MarksPainter(_marks), size: Size.infinite),
                            if (_busy)
                              const ColoredBox(color: Color(0x55000000), child: Center(child: CircularProgressIndicator(color: Colors.white))),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                _toolBar(),
              ],
            ),
    );
  }

  Widget _toolBar() {
    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xFF101114),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 66,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: EditTool.values.map((tool) => _EditToolButton(icon: switch (tool) { EditTool.effect => Icons.auto_awesome, EditTool.adjust => Icons.tune, EditTool.erase => Icons.auto_fix_high, EditTool.crop => Icons.crop, EditTool.transform => Icons.rotate_90_degrees_ccw, EditTool.annotate => Icons.draw_outlined }, label: _toolName(tool), active: _tool == tool, onTap: () => setState(() => _tool = tool))).toList(),
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            _toolPanel(),
          ],
        ),
      ),
    );
  }

  Widget _toolPanel() {
    switch (_tool) {
      case EditTool.effect:
        return SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: EditorEffect.values.map((e) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(label: Text(_effectName(e)), selected: _effect == e, onSelected: (_) => _applyEffect(e)),
            )).toList(),
          ),
        );
      case EditTool.adjust:
        return Column(children: [
          _sliderRow('Brightness', _brightness, -100, 100, (v) => setState(() => _brightness = v)),
          _sliderRow('Contrast', _contrast, -100, 100, (v) => setState(() => _contrast = v)),
          _sliderRow('Saturation', _saturation, -100, 100, (v) => setState(() => _saturation = v)),
          _sliderRow('Temperature', _temperature, -100, 100, (v) => setState(() => _temperature = v)),
          _sliderRow('Sharpness', _sharpness, 0, 100, (v) => setState(() => _sharpness = v)),
          _sliderRow('Highlights', _highlights, -100, 100, (v) => setState(() => _highlights = v)),
          _sliderRow('Shadows', _shadows, -100, 100, (v) => setState(() => _shadows = v)),
          FilledButton.icon(onPressed: _busy ? null : _applyAdjustments, icon: const Icon(Icons.check), label: const Text('TERAPKAN ADJUST')),
        ]);
      case EditTool.erase:
        return Column(children: [
          SegmentedButton<EraseMode>(segments: const [ButtonSegment(value: EraseMode.auto, label: Text('AUTO'), icon: Icon(Icons.auto_fix_high)), ButtonSegment(value: EraseMode.manual, label: Text('MANUAL'), icon: Icon(Icons.brush_outlined))], selected: {_eraseMode}, onSelectionChanged: (s) => setState(() => _eraseMode = s.first)),
          const SizedBox(height: 8),
          Text(_eraseMode == EraseMode.auto ? 'Tap objek yang ingin dihapus. Aplikasi akan memilih area otomatis.' : 'Gambar pada objek yang ingin dihapus.', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (_eraseMode == EraseMode.manual) Row(children: [const Icon(Icons.brush, color: Colors.white70), Expanded(child: Slider(value: _brush, min: 12, max: 100, onChanged: (v) => setState(() => _brush = v))), Text('${_brush.round()}', style: const TextStyle(color: Colors.white70))]),
          if (_eraseMode == EraseMode.manual) FilledButton.icon(onPressed: _busy ? null : _applyManualErase, icon: const Icon(Icons.auto_fix_high), label: const Text('HAPUS AREA')),
        ]);
      case EditTool.crop:
        return Column(children: [
          const Text('Tarik pada foto untuk memilih area crop.', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          Row(children: [Expanded(child: FilledButton.icon(onPressed: _busy ? null : _applyCrop, icon: const Icon(Icons.crop), label: const Text('CROP'))), const SizedBox(width: 8), OutlinedButton(onPressed: () => setState(() { _cropStartX = .12; _cropStartY = .12; _cropEndX = .88; _cropEndY = .88; }), child: const Text('RESET AREA'))]),
        ]);
      case EditTool.transform:
        return Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: _busy ? null : () => _rotate(1), icon: const Icon(Icons.rotate_right), label: const Text('PUTAR 90°')),
          FilledButton.icon(onPressed: _busy ? null : () => _rotate(2), icon: const Icon(Icons.screen_rotation_alt), label: const Text('180°')),
          OutlinedButton.icon(onPressed: _busy ? null : () => _flip(true), icon: const Icon(Icons.flip), label: const Text('FLIP H')),
          OutlinedButton.icon(onPressed: _busy ? null : () => _flip(false), icon: const Icon(Icons.flip_camera_android), label: const Text('FLIP V')),
        ]);
      case EditTool.annotate:
        return Column(children: [
          SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, children: AnnotationMode.values.map((m) => Padding(padding: const EdgeInsets.only(right: 7), child: ChoiceChip(label: Text(switch (m) { AnnotationMode.circle => 'LINGKARAN', AnnotationMode.rectangle => 'KOTAK', AnnotationMode.arrow => 'PANAH', AnnotationMode.text => 'TEKS', AnnotationMode.number => 'NOMOR' }), selected: _annotationMode == m, onSelected: (_) => setState(() => _annotationMode = m)))).toList())),
          const SizedBox(height: 6),
          const Text('Tandai bagian barang yang rusak sebelum menyimpan.', style: TextStyle(color: Colors.white70, fontSize: 12)),
          Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _marks.isEmpty ? null : () => setState(() => _marks.removeLast()), icon: const Icon(Icons.undo), label: const Text('HAPUS TANDA TERAKHIR'))), const SizedBox(width: 8), OutlinedButton.icon(onPressed: _marks.isEmpty ? null : () => setState(() => _marks.clear()), icon: const Icon(Icons.clear_all), label: const Text('BERSIHKAN'))]),
        ]);
    }
  }

  Widget _sliderRow(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(children: [SizedBox(width: 88, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))), Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)), SizedBox(width: 42, child: Text(value.round().toString(), textAlign: TextAlign.right, style: const TextStyle(color: Colors.white70, fontSize: 11)))]);
  }
}

class _EditorMark {
  final AnnotationMode mode;
  final Offset start;
  final Offset end;
  final String? text;
  const _EditorMark({required this.mode, required this.start, required this.end, this.text});
  _EditorMark copyWith({Offset? end}) => _EditorMark(mode: mode, start: start, end: end ?? this.end, text: text);
}

class _EditToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _EditToolButton({required this.icon, required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(width: 82, child: InkWell(onTap: onTap, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Container(width: 38, height: 38, decoration: BoxDecoration(color: active ? Colors.blue : Colors.white10, borderRadius: BorderRadius.circular(11)), child: Icon(icon, color: Colors.white, size: 20)), const SizedBox(height: 4), Text(label, style: TextStyle(color: active ? Colors.white : Colors.white60, fontSize: 10, fontWeight: FontWeight.w700))])));
}

class _EditorStrokePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> current;
  final double brush;
  _EditorStrokePainter(this.strokes, this.current, this.brush);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.red.withValues(alpha: .42)..strokeWidth = brush..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    for (final stroke in [...strokes, if (current.isNotEmpty) current]) {
      for (var i = 1; i < stroke.length; i++) {
        canvas.drawLine(Offset(stroke[i - 1].dx * size.width, stroke[i - 1].dy * size.height), Offset(stroke[i].dx * size.width, stroke[i].dy * size.height), p);
      }
    }
  }
  @override
  bool shouldRepaint(covariant _EditorStrokePainter oldDelegate) => true;
}

class _AutoPointPainter extends CustomPainter {
  final Offset point;
  _AutoPointPainter(this.point);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(point.dx * size.width, point.dy * size.height);
    final p = Paint()..color = Colors.blueAccent..style = PaintingStyle.stroke..strokeWidth = 3;
    canvas.drawCircle(center, 28, p);
    canvas.drawLine(center - const Offset(38, 0), center + const Offset(38, 0), p);
    canvas.drawLine(center - const Offset(0, 38), center + const Offset(0, 38), p);
  }
  @override
  bool shouldRepaint(covariant _AutoPointPainter oldDelegate) => oldDelegate.point != point;
}

class _CropPainter extends CustomPainter {
  final double sx, sy, ex, ey;
  _CropPainter(this.sx, this.sy, this.ex, this.ey);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(math.min(sx, ex) * size.width, math.min(sy, ey) * size.height, math.max(sx, ex) * size.width, math.max(sy, ey) * size.height);
    final shade = Paint()..color = Colors.black.withValues(alpha: .48);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), shade);
    canvas.drawRect(rect, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
  }
  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) => true;
}

class _MarksPainter extends CustomPainter {
  final List<_EditorMark> marks;
  _MarksPainter(this.marks);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.redAccent..style = PaintingStyle.stroke..strokeWidth = 3;
    for (final m in marks) {
      final s = Offset(m.start.dx * size.width, m.start.dy * size.height);
      final e = Offset(m.end.dx * size.width, m.end.dy * size.height);
      switch (m.mode) {
        case AnnotationMode.circle:
          canvas.drawOval(Rect.fromPoints(s, e), p);
          break;
        case AnnotationMode.rectangle:
          canvas.drawRect(Rect.fromPoints(s, e), p);
          break;
        case AnnotationMode.arrow:
          canvas.drawLine(s, e, p);
          final angle = math.atan2(e.dy - s.dy, e.dx - s.dx);
          const len = 16.0;
          canvas.drawLine(e, e + Offset(math.cos(angle + 2.6) * len, math.sin(angle + 2.6) * len), p);
          canvas.drawLine(e, e + Offset(math.cos(angle - 2.6) * len, math.sin(angle - 2.6) * len), p);
          break;
        case AnnotationMode.text:
          final tp = TextPainter(text: TextSpan(text: m.text ?? '', style: const TextStyle(color: Colors.redAccent, fontSize: 22, fontWeight: FontWeight.w900)), textDirection: TextDirection.ltr)..layout();
          tp.paint(canvas, s);
          break;
        case AnnotationMode.number:
          canvas.drawCircle(s, 20, p);
          final tp = TextPainter(text: TextSpan(text: m.text ?? '1', style: const TextStyle(color: Colors.redAccent, fontSize: 20, fontWeight: FontWeight.w900)), textDirection: TextDirection.ltr)..layout();
          tp.paint(canvas, s - Offset(tp.width / 2, tp.height / 2));
          break;
      }
    }
  }
  @override
  bool shouldRepaint(covariant _MarksPainter oldDelegate) => true;
}
