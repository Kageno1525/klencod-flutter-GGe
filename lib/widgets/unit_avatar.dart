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

    // الكود ده بيشتغل بس لو الصورة ليها "طابع زمني" (Sprite Sheet)
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

      // تحميل JSON
      final reqJson = await client.getUrl(Uri.parse(jsonUrl));
      final resJson = await reqJson.close();
      if (resJson.statusCode != 200) return null;
      final bodyJson = await resJson.transform(utf8.decoder).join();

      // تحميل JS
      final reqJs = await client.getUrl(Uri.parse(jsUrl));
      final resJs = await reqJs.close();
      if (resJs.statusCode != 200) return null;
      final bodyJs = await resJs.transform(utf8.decoder).join();

      client.close();

      final json = jsonDecode(bodyJson) as Map<String, dynamic>;
      final framesJson = json['frames'] as List;
      if (framesJson.length != 4) return null; // مش من النوع ده

      // استخراج الإحداثيات من الـ JS
      final reg = RegExp(
          r'this\.bitmap_1\.x=([-\d.]+),this\.bitmap_1\.y=([-\d.]+),.*?this\.c2\.x=([-\d.]+),this\.c2\.y=([-\d.]+),this\.c2\.scaleX=([-\d.]+),this\.c2\.scaleY=([-\d.]+),.*?this\.c1\.x=([-\d.]+),this\.c1\.y=([-\d.]+),this\.c1\.scaleX=([-\d.]+),this\.c1\.scaleY=([-\d.]+),.*?this\.bitmap_2\.x=([-\d.]+),this\.bitmap_2\.y=([-\d.]+)');
      final match = reg.firstMatch(bodyJs);
      if (match == null) return null;

      final x1 = double.parse(match.group(1)!);
      final y1 = double.parse(match.group(2)!);
      final x2 = double.parse(match.group(3)!);
      final y2 = double.parse(match.group(4)!);
      final sx2 = double.parse(match.group(5)!);
      final sy2 = double.parse(match.group(6)!);
      final x3 = double.parse(match.group(7)!);
      final y3 = double.parse(match.group(8)!);
      final sx3 = double.parse(match.group(9)!);
      final sy3 = double.parse(match.group(10)!);
      final x4 = double.parse(match.group(11)!);
      final y4 = double.parse(match.group(12)!);

      final f0 = framesJson[0] as List;
      final f1 = framesJson[1] as List;
      final f2 = framesJson[2] as List;
      final f3 = framesJson[3] as List;

      return SpriteData(
        imageUrl: webpUrl,
        frames: [
          SpriteFrame(srcX: f2[0].toDouble(), srcY: f2[1].toDouble(), w: f2[2].toDouble(), h: f2[3].toDouble(), x: x1, y: y1, scaleX: 1, scaleY: 1),
          SpriteFrame(srcX: f1[0].toDouble(), srcY: f1[1].toDouble(), w: f1[2].toDouble(), h: f1[3].toDouble(), x: x2, y: y2, scaleX: sx2, scaleY: sy2),
          SpriteFrame(srcX: f0[0].toDouble(), srcY: f0[1].toDouble(), w: f0[2].toDouble(), h: f0[3].toDouble(), x: x3, y: y3, scaleX: sx3, scaleY: sy3),
          SpriteFrame(srcX: f3[0].toDouble(), srcY: f3[1].toDouble(), w: f3[2].toDouble(), h: f3[3].toDouble(), x: x4, y: y4, scaleX: 1, scaleY: 1),
        ],
      );
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

    // رسم القطع فوق بعض
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