import 'package:flutter/material.dart';

import 'aerial.dart';
import 'game.dart';
import 'travel.dart';

final Map<String, GameModule> _modules = {
  for (final g in const <GameModule>[TravelGame(), AerialGame()]) g.id: g,
};

/// Adds a game. A new game is one module and one line in the list above; tests add their own.
void registerGame(GameModule module) => _modules[module.id] = module;

/// The module of a game, or null for a game still handled directly in the pages.
GameModule? gameModule(String id) => _modules[id];

/// The games a teacher can pick from, in this order, then any other registered game.
const _order = ['travel', 'coordinates', 'aerial', 'evidence', 'mapping', 'cards', 'plates', 'puzzle', 'layout'];

List<String> pickableGames() => [..._order, ..._modules.keys.where((id) => !_order.contains(id))];

IconData gameIcon(String id) =>
    gameModule(id)?.icon ??
    switch (id) {
      'coordinates' => Icons.my_location,
      'mapping' => Icons.draw,
      'cards' => Icons.style,
      'evidence' => Icons.receipt_long,
      'plates' => Icons.palette_outlined,
      'puzzle' => Icons.extension,
      'layout' => Icons.map_outlined,
      _ => Icons.travel_explore,
    };
