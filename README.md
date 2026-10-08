# Conquera

Bare-bones world map for a war game. Light-themed, pan/zoom, tap a province to highlight it.

## Setup
1. Copy your real `world.svg` from Urbanize over `assets/maps/world.svg` (a small placeholder is included so the project runs).
2. Platform folders (android/ios/web...) are not included. From this folder run:
   `flutter create --project-name conquera .`
   It adds the platform scaffolding and leaves existing `lib/` and `pubspec.yaml` alone.
3. `flutter pub get && flutter run`

## Structure
- `lib/services/svg_map_parser.dart` - unchanged from Urbanize
- `lib/models/province.dart`, `lib/services/map_parse_result.dart` - unchanged from Urbanize
- `lib/state/map_controller.dart` - load + tap selection (no dice/neighbors/economy)
- `lib/painters/map_painter.dart` - light-theme painter with selected highlight
- `lib/screens/map_screen.dart` - InteractiveViewer + tap detection
- `lib/theme/conquera_theme.dart` - all colors in one place
