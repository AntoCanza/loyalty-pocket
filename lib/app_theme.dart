import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/app_localizations.dart';

abstract final class AppTheme {
  static const _brand = Color(0xFF123B34);

  static final light = _build(Brightness.light, const Color(0xFFF3F6F0));
  static final dark = _build(Brightness.dark, const Color(0xFF101713));

  static ThemeData _build(Brightness brightness, Color canvas) {
    final colors = ColorScheme.fromSeed(
      seedColor: _brand,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colors,
      scaffoldBackgroundColor: canvas,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: brightness == Brightness.light
            ? _brand
            : colors.onSurface,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }
}

abstract final class AppThemePreference {
  static Future<void> _pendingWrite = Future<void>.value();

  static Future<ThemeMode> read() async {
    try {
      await _pendingWrite;
      final file = await _file();
      final value = await file.readAsString();
      return ThemeMode.values.where((mode) => mode.name == value).firstOrNull ??
          ThemeMode.system;
    } catch (_) {
      return ThemeMode.system;
    }
  }

  static Future<void> write(ThemeMode mode) {
    final result = _pendingWrite.then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(mode.name, flush: true);
      await temporary.rename(file.path);
    });
    _pendingWrite = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}theme-mode');
  }
}

class AppThemeButton extends StatelessWidget {
  const AppThemeButton({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<ThemeMode>(
      icon: const Icon(Icons.brightness_6_outlined),
      tooltip: l10n.themeAppearance,
      initialValue: mode,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final option in ThemeMode.values)
          CheckedPopupMenuItem(
            value: option,
            checked: mode == option,
            child: Text(switch (option) {
              ThemeMode.system => l10n.themeSystem,
              ThemeMode.light => l10n.themeLight,
              ThemeMode.dark => l10n.themeDark,
            }),
          ),
      ],
    );
  }
}
