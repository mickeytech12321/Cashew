import 'dart:math' as math;
import 'package:flutter/material.dart';

String cashuLabel(BuildContext context, String en, String ar) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

class CashuColors {
  CashuColors(BuildContext context)
      : dark = Theme.of(context).brightness == Brightness.dark,
        black = Theme.of(context).scaffoldBackgroundColor == Colors.black;

  final bool dark;
  final bool black;

  Color get canvas => dark
      ? (black ? Colors.black : const Color(0xff111816))
      : const Color(0xfff2f5ef);
  Color get panel => dark ? const Color(0xff202a26) : const Color(0xfffcfdf9);
  Color get border => dark ? const Color(0xff34463e) : const Color(0xffdbe6dc);
  Color get ink => dark ? const Color(0xffeff8f0) : const Color(0xff17271f);
  Color get muted => dark ? const Color(0xffb5c9be) : const Color(0xff526559);
  Color get accent => dark ? const Color(0xffb4edb8) : const Color(0xff276047);
  Color get tint => dark ? const Color(0xff2c4438) : const Color(0xffe1efe2);
}

class CashuPanel extends StatelessWidget {
  const CashuPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.highlighted = false,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    return Material(
      color: highlighted ? colors.tint : colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(19),
        side: BorderSide(color: highlighted ? colors.accent : colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child:
          InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

class CashuIconTile extends StatelessWidget {
  const CashuIconTile(this.icon, {super.key, this.size = 44});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: colors.tint, borderRadius: BorderRadius.circular(14)),
      child: Icon(icon, size: size * .50, color: colors.accent),
    );
  }
}

class CashuSectionTitle extends StatelessWidget {
  const CashuSectionTitle(this.title, {super.key, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 10),
        child: Row(children: [
          Expanded(
              child: Text(title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: CashuColors(context).ink,
                        fontWeight: FontWeight.w800,
                      ))),
          if (action != null) action!,
        ]),
      );
}

class CashuGreenPanel extends StatelessWidget {
  const CashuGreenPanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = CashuColors(context).dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: dark
              ? const [Color(0xff1b352c), Color(0xff101f19)]
              : const [Color(0xff254b3b), Color(0xff142d26)],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: CustomPaint(
          painter: const _LedgerLines(),
          child: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    );
  }
}

class _LedgerLines extends CustomPainter {
  const _LedgerLines();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0x23c9f0b5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final center = Offset(size.width * .96, size.height * .28);
    for (var radius = 40.0; radius <= 175; radius += 16) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
          math.pi * .53, math.pi * .91, false, line);
    }
  }

  @override
  bool shouldRepaint(_LedgerLines oldDelegate) => false;
}

class CashuActionRow extends StatelessWidget {
  const CashuActionRow({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 2, 12, 2),
      leading: CashuIconTile(icon, size: 36),
      title: Text(title,
          style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700)),
      subtitle: detail == null
          ? null
          : Text(detail!, style: TextStyle(color: colors.muted)),
      trailing: onTap == null
          ? null
          : Icon(
              Directionality.of(context) == TextDirection.rtl
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              color: colors.muted,
            ),
      onTap: onTap,
    );
  }
}

class CashuOptionSection extends StatelessWidget {
  const CashuOptionSection({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.initiallyExpanded = false,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final bool initiallyExpanded;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    return CashuPanel(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsetsDirectional.fromSTEB(12, 3, 12, 3),
        childrenPadding:
            const EdgeInsetsDirectional.only(start: 10, end: 10, bottom: 10),
        leading: CashuIconTile(icon, size: 36),
        title: Text(title,
            style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700)),
        subtitle: detail == null
            ? null
            : Text(detail!, style: TextStyle(color: colors.muted)),
        children: children,
      ),
    );
  }
}

InputDecoration cashuInput(BuildContext context, String label,
    {String? suffix}) {
  final colors = CashuColors(context);
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(13),
    borderSide: BorderSide(color: colors.border),
  );
  return InputDecoration(
    labelText: label,
    suffixText: suffix,
    filled: true,
    fillColor: colors.canvas,
    border: border,
    enabledBorder: border,
  );
}
