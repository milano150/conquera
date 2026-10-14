# Conquera

Conquera is a small multiplayer world-war game built in Flutter. The idea is pretty simple: join a game world, pick a name and color, take over provinces on a map, build up your economy, and try to outgrow everyone else before the map gets locked down.

This started as a map-first prototype: a styled world map with pan + zoom, tap-to-select territory, and basic game logic layered on top. It has since grown into a full-ish strategy loop with Firebase-backed state, player ownership, attack flows, gold income, and a rough live-world multiplayer setup.

I wanted it to feel like a lightweight, browserless Risk/Conquer-style game that still runs well on mobile and is easy to iterate on.

## What it does

- lets players join a world by id
- assigns a color and starting territory on first join
- shows a pannable, zoomable world map with province hit detection
- tracks players, province ownership, and troop counts in Firestore
- supports claiming and attacking neighboring provinces
- gives each player gold income from owned territory and buildings
- lets players build on provinces with economy/defense bonuses
- keeps the game state live for multiple players in the same world

## Tech stack

- Flutter
- Firebase Auth
- Cloud Firestore
- custom SVG world parsing for province geometry
- a light custom theme and map painter pipeline

## Current status

This is still very much in beta. The core map interactions, ownership model, and multiplayer flow are there, but there are still rough edges and some gameplay balance / polish work left.

The project is intentionally set up around a real-world-style SVG map and a live state layer, which makes it easy to build on top of without rewriting the whole foundation.

## Getting started

### Prerequisites

- Flutter SDK installed
- Firebase project configured for the app
- a real `world.svg` asset for the map in `assets/maps/world.svg`

### 1) Install dependencies

```bash
flutter pub get
```

### 2) Set up Firebase

This app uses Firebase Auth and Firestore.

If you haven't already:

```bash
flutterfire configure
```

This generates the Firebase config files used by the app.

### 3) Add the world map

The app expects the map asset at:

```text
assets/maps/world.svg
```

The project includes a placeholder asset so it can run, but for the actual game you should replace it with your real world map SVG.

### 4) Run it

```bash
flutter run
```

If the project is freshly created and platform folders are missing, you can generate them with:

```bash
flutter create --project-name conquera .
```

That adds the Flutter platform scaffolding without stomping the custom `lib/` code or `pubspec.yaml` setup.

## Project layout

```text
lib/
├── config/
│   ├── country_data.dart
│   ├── dev_session.dart
│   ├── game_rules.dart
│   ├── player_colors.dart
│   ├── sea_links.dart
│   └── territory_types.dart
├── models/
│   ├── attack_result.dart
│   ├── player_state.dart
│   ├── province_state.dart
│   └── province.dart
├── painters/
│   └── map_painter.dart
├── screens/
│   ├── home_screen.dart
│   ├── join_screen.dart
│   └── map_screen.dart
├── services/
│   ├── border_finder.dart
│   ├── firestore_service.dart
│   ├── map_parse_result.dart
│   └── svg_map_parser.dart
├── state/
│   └── map_controller.dart
├── theme/
│   └── conquera_theme.dart
├── widgets/
│   ├── attack_dialog.dart
│   ├── blur_route.dart
│   ├── conquera_text_field.dart
│   ├── country_info_panel.dart
│   ├── fade_route.dart
│   ├── gold_amount.dart
│   ├── leaderboard_panel.dart
│   ├── map_viewport.dart
│   ├── player_tag.dart
│   ├── player_top_bar.dart
│   ├── province_detail_dialog.dart
│   ├── stat_block.dart
│   └── world_sidebar.dart
├── firebase_options.dart
├── main.dart
└── ...
```

## Core gameplay loop

The game loop is intentionally simple:

1. a player joins a world
2. they claim a starting territory and begin with some gold
3. they expand over nearby land or attack a weak neighbor
4. taxes and buildings generate income over time
5. a bigger economy means more reinforcements, more claims, and more pressure on the map

The balance layer lives in `lib/config/game_rules.dart`, which centralizes the economy, attack rules, building costs, and unit values so it stays easy to tune while the game grows.

## Map system

The world map is generated from an SVG, with provinces parsed out into geometry and hit regions. That gives the project a nice separation between the map asset itself and the gameplay layer: the map is mostly a visual shell, while the game logic decides who owns what and how fights resolve.

The actual view is built around a zoomable camera and tap detection layer, which makes the map feel playable rather than just decorative.

## Notes from the dev bench

A few things are still intentionally rough around the edges:

- the game is still in a beta / prototype phase
- map balance and economy tuning need more iteration
- the world setup and multiplayer flow still assume a small, controlled game environment
- there are still some “make it feel less janky” items on the backlog

This is one of those projects where the fun part is in the loop: getting a world, taking a border, holding your own, and making the little map feel like a real conflict zone.

## Roadmap / next ideas

The obvious next steps are the stuff that turns a fun prototype into a real playable strategy game:

- better balance pass on attack and economy numbers
- more building types and province-specific bonuses
- smarter AI or more robust multiplayer interactions
- better battle feedback and event readability
- cleaner world/room creation flow
- polish for mobile UX and visual clarity

## License

This project is currently unlicensed and intended as a personal / experimental codebase.


