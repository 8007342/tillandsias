# Flutter Development

## Architecture
- Clean Architecture: presentation (widgets) -> domain (use cases) -> data (repos)
- State management: Riverpod (preferred) or BLoC
- Navigation: GoRouter
- i18n: flutter_localizations + ARB files from day one

## Code Style
- Prefer StatelessWidget over StatefulWidget
- Use const constructors everywhere possible
- Material 3 theming with ColorScheme.fromSeed()
- Responsive layouts with LayoutBuilder or MediaQuery

## Testing
- Widget tests for all screens
- Unit tests for business logic
- Integration tests for critical flows
