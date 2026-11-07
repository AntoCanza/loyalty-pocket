import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loyalty_pocket/app_theme.dart';
import 'package:loyalty_pocket/l10n/app_localizations.dart';

void main() {
  testWidgets('chooses dark mode from the localized appearance menu', (
    tester,
  ) async {
    var mode = ThemeMode.system;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          locale: const Locale('it'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppThemeButton(
                  mode: mode,
                  onChanged: (value) => setState(() => mode = value),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Aspetto'));
    await tester.pumpAndSettle();

    expect(find.text('Come il dispositivo'), findsOneWidget);
    expect(find.text('Chiaro'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<ThemeMode>, 'Scuro'),
    );
    await tester.pumpAndSettle();

    expect(mode, ThemeMode.dark);
    final context = tester.element(find.byType(AppThemeButton));
    expect(Theme.of(context).brightness, Brightness.dark);
  });
}
