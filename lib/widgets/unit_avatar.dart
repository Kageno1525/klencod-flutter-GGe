import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models.dart';
import '../theme.dart';

class SpriteData {
  final String imageUrl;
  final List<SpriteFrame> frames;
  SpriteData({required this.imageUrl, required this.frames});
}

class SpriteFrame {
  final double srcX, srcY, w, h;
  final double x, y, scaleX, scaleY;
  SpriteFrame({
    required this.srcX, required this.srcY,
    required this.w, required this.h,
    required this.x, required this.y,
    required this.scaleX, required this.scaleY,
  });
}

class UnitAvatar extends StatefulWidget {
  final UnitCatalogEntry? info;
  final double size;
  final VoidCallback? onLongPress;
  final Color? tint;

  const UnitAvatar({
    super.key,
    required this.info,
    this.size = 44,
    this.onLongPress,
    this.tint,
  });

  @override
  State<UnitAvatar> createState() => _UnitAvatarState();
}

class _UnitAvatarState extends State<UnitAvatar> {
  static final Map<String, SpriteData?> _spriteCache = {};
  static final Map<String, ui.Image> _imageCache = {};

  SpriteData? _spriteData;
  ui.Image? _image;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(UnitAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.info?.imageUrl != oldWidget.info?.imageUrl) {
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.info?.imageUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // لو الصورة من نوع Sprite Sheet (فيها تاريخ زمني --123456)
    if (url.contains('--') && (url.endsWith('.webp') || url.endsWith('.png'))) {
      if (_spriteCache.containsKey(url)) {
        _spriteData = _spriteCache[url];
        _image = _imageCache[url];
      } else {
        final data = await _fetchSpriteData(url);
        _spriteCache[url] = data;
        _spriteData = data;

        if (data != null) {
          try {
            final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
            final completer = Completer<ui.Image>();
            stream.addListener(ImageStreamListener((info, _) {
              if (!completer.isCompleted) completer.complete(info.image);
            }, onError: (e, _) {
              if (!completer.isCompleted) completer.completeError(e);
            }));
            final img = await completer.future;
            _imageCache[url] = img;
            _image = img;
          } catch (e) {
            _spriteData = null;
            _spriteCache[url] = null;
          }
        }
      }
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<SpriteData?> _fetchSpriteData(String webpUrl) async {
    final jsonUrl = webpUrl.replaceFirst(RegExp(r'\.(webp|png)$'), '.json');
    final jsUrl = webpUrl.replaceFirst(RegExp(r'\.(webp|png)$'), '.js');

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      final reqJson = await client.getUrl(Uri.parse(jsonUrl));
      final resJson = await reqJson.close();
      if (resJson.statusCode != 200) return null;
      final bodyJson = await resJson.transform(utf8.decoder).join();

      final reqJs = await client.getUrl(Uri.parse(jsUrl));
      final resJs = await reqJs.close();
      if (resJs.statusCode != 200) return null;
      final bodyJs = await resJs.transform(utf8.decoder).join();

      client.close();

      final json = jsonDecode(bodyJson) as Map<String, dynamic>;
      final framesList = json['frames'] as List?;
      final animations = json['animations'] as Map<String, dynamic>?;
      if (framesList == null || animations == null) return null;

      final bmpToFrame = <String, List>{};
      for (final e in animations.entries) {
        final fList = (e.value as Map)['frames'] as List;
        if (fList.isNotEmpty) {
          bmpToFrame[e.key] = framesList[fList[0] as int] as List;
        }
      }

      // 1. استخراج إحداثيات كل قطعة من ملف JS
      final offsets = <String, Map<String, double>>{};
      final offsetMatches = RegExp(r'this\.([a-zA-Z0-9_]+)\.x=([-\d.]+),this\.\1\.y=([-\d.]+)(?:,this\.\1\.scaleX=([-\d.]+),this\.\1\.scaleY=([-\d.]+))?').allMatches(bodyJs);
      for (final m in offsetMatches) {
        offsets[m.group(1)!] = {
          'x': double.parse(m.group(2)!),
          'y': double.parse(m.group(3)!),
          'scaleX': double.tryParse(m.group(4) ?? '1') ?? 1.0,
          'scaleY': double.tryParse(m.group(5) ?? '1') ?? 1.0,
        };
      }

      // 2. استخراج ترتيب الرسم (مين فوق مين)
      final addChildRegex = RegExp(r'this\.addChild\(([^)]+)\)');
      final addChildMatch = addChildRegex.firstMatch(bodyJs);
      final drawOrder = <String>[];
      if (addChildMatch != null) {
        final args = addChildMatch.group(1)!.split(',');
        for (final arg in args) {
          final name = arg.trim().split('.').last;
          drawOrder.add(name);
        }
      } else {
        drawOrder.addAll(['bitmap_1', 'c2', 'c1', 'bitmap_2']); // ترتيب افتراضي
      }

      // 3. دالة ذكية لمعرفة كل قطعة بتشاور على أنهي صورة في الـ JSON
      String? findBmpForClass(String className, String js) {
        final aliasRegex = RegExp('var\\s+$className\\s*=\\s*([a-zA-Z0-9_]+)');
        final aliasMatch = aliasRegex.firstMatch(js);
        if (aliasMatch != null) className = aliasMatch.group(1)!;

        final funcRegex = RegExp('function\\s+$className\\s*\\(\\)\\s*\\{[^}]*?getAnimation\\("(BMP_\\d)"\\)');
        final funcMatch = funcRegex.firstMatch(js);
        if (funcMatch != null) return funcMatch.group(1);

        final innerRegex = RegExp('function\\s+$className\\s*\\(\\)\\s*\\{[^}]*?this\\.\\w+\\s*=\\s*new\\s+([a-zA-Z0-9_]+)');
        final innerMatch = innerRegex.firstMatch(js);
        if (innerMatch != null) return findBmpForClass(innerMatch.group(1)!, js);

        return null;
      }

      String? findBmpForElement(String element, String js) {
        final instRegex = RegExp('this\\.$element\\s*=\\s*new\\s+([a-zA-Z0-9_]+)');
        final instMatch = instRegex.firstMatch(js);
        if (instMatch != null) {
          return findBmpForClass(instMatch.group(1)!, js);
        }
        return null;
      }

      final list = <SpriteFrame>[];
      for (final element in drawOrder) {
        var bmp = findBmpForElement(element, bodyJs);
        // خطة بديلة لو الدالة الذكية فشلت في التعرف
        if (bmp == null) {
          if (element == 'bitmap_1') bmp = 'BMP_0';
          else if (element == 'c1') bmp = 'BMP_2';
          else if (element == 'c2') bmp = 'BMP_3';
          else if (element == 'bitmap_2') bmp = 'BMP_1';
        }

        if (bmp != null && bmpToFrame.containsKey(bmp)) {
          final frame = bmpToFrame[bmp]!;
          final offset = offsets[element] ?? {'x': 0.0, 'y': 0.0, 'scaleX': 1.0, 'scaleY': 1.0};
          list.add(SpriteFrame(
            srcX: (frame[0] as num).toDouble(),
            srcY: (frame[1] as num).toDouble(),
            w: (frame[2] as num).toDouble(),
            h: (frame[3] as num).toDouble(),
            x: offset['x']!,
            y: offset['y']!,
            scaleX: offset['scaleX']!,
            scaleY: offset['scaleY']!,
          ));
        }
      }

      if (list.isNotEmpty) {
        return SpriteData(imageUrl: webpUrl, frames: list);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.info?.imageUrl;
    final color = widget.tint ?? _defaultColor();

    Widget child;

    if (_loading) {
      child = Center(
        child: SizedBox(
          width: widget.size * 0.35,
          height: widget.size * 0.35,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
      );
    } else if (_spriteData != null && _image != null) {
      // الصورة اتجمعت بنجاح
      child = CustomPaint(
        painter: SpritePainter(_image!, _spriteData!.frames),
        size: Size(widget.size, widget.size),
      );
    } else if (url == null || url.isEmpty) {
      child = _iconFallback(color);
    } else {
      // صورة عادية
      child = Padding(
        padding: EdgeInsets.all(widget.size * 0.06),
        child: Image.network(
          url,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _iconFallback(color),
        ),
      );
    }

    final content = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(widget.size * 0.22),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    if (widget.onLongPress == null) return content;
    return GestureDetector(
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }

  Color _defaultColor() {
    if (widget.info?.role == 'ranged') return AppTheme.teal;
    if (widget.info?.role == 'melee') return AppTheme.red;
    return AppTheme.purple;
  }

  Widget _iconFallback(Color color) {
    final icon = widget.info?.role == 'ranged'
        ? Icons.gps_fixed_rounded
        : widget.info?.role == 'melee'
            ? Icons.gavel_rounded
            : Icons.shield_rounded;
    return Icon(icon, color: color, size: widget.size * 0.45);
  }
}

class SpritePainter extends CustomPainter {
  final ui.Image image;
  final List<SpriteFrame> frames;

  SpritePainter(this.image, this.frames);

  @override
  void paint(Canvas canvas, Size size) {
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (final f in frames) {
      final left = f.x;
      final top = f.y;
      final right = left + f.w * f.scaleX;
      final bottom = top + f.h * f.scaleY;
      if (left < minX) minX = left;
      if (top < minY) minY = top;
      if (right > maxX) maxX = right;
      if (bottom > maxY) maxY = bottom;
    }

    final totalW = maxX - minX;
    final totalH = maxY - minY;
    if (totalW <= 0 || totalH <= 0) return;

    final scale = math.min(size.width / totalW, size.height / totalH);

    canvas.save();
    // توسيط الصورة في المربع
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-(minX + maxX) / 2, -(minY + maxY) / 2);

    final paint = Paint()..filterQuality = FilterQuality.high;

    // رسم القطع فوق بعض بالترتيب الصح
    for (final f in frames) {
      canvas.save();
      canvas.translate(f.x, f.y);
      canvas.scale(f.scaleX, f.scaleY);
      final srcRect = Rect.fromLTWH(f.srcX, f.srcY, f.w, f.h);
      final dstRect = Rect.fromLTWH(0, 0, f.w, f.h);
      canvas.drawImageRect(image, srcRect, dstRect, paint);
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SpritePainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.frames != frames;
  }
}