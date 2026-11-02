import 'package:flutter/material.dart';
import '../models.dart';
import '../theme.dart';

class UnitAvatar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final url = info?.imageUrl;
    final color = tint ?? _defaultColor();

    final content = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(size * 0.22),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? _iconFallback(color)
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _iconFallback(color),
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return Center(
                  child: SizedBox(
                    width: size * 0.35,
                    height: size * 0.35,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  ),
                );
              },
            ),
    );

    if (onLongPress == null) return content;
    return GestureDetector(
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }

  Color _defaultColor() {
    if (info?.role == 'ranged') return AppTheme.teal;
    if (info?.role == 'melee') return AppTheme.red;
    return AppTheme.purple;
  }

  Widget _iconFallback(Color color) {
    final icon = info?.role == 'ranged'
        ? Icons.gps_fixed_rounded
        : info?.role == 'melee'
            ? Icons.gavel_rounded
            : Icons.shield_rounded;
    return Icon(icon, color: color, size: size * 0.45);
  }
}