import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

class VersusParticipant {
  VersusParticipant(this.path, this.createdAt);

  final String path;
  final DateTime createdAt;
  int bestRoundReached = 1;
  bool isWinner = false;

  String get resultText => isWinner ? 'Winner' : 'Reached round $bestRoundReached';
}

/// Single-elimination tournament between images of a cell (the WebuiMultiflex "Versus" page).
///
/// Every round is played by the largest power of two of the remaining images, in random pairs;
/// the newest images that do not fit get a bye into the next round.
class VersusTournament extends ChangeNotifier {
  VersusTournament(List<VersusParticipant> participants, {Random? random}) : _random = random ?? Random() {
    restart(participants);
  }

  final Random _random;
  List<VersusParticipant> _participants = [];
  List<VersusParticipant> _active = [];
  List<VersusParticipant> _roundByes = [];
  List<VersusParticipant> _roundWinners = [];
  final Queue<(VersusParticipant, VersusParticipant)> _roundMatches = Queue();
  final List<VersusParticipant> results = [];

  VersusParticipant? left;
  VersusParticipant? right;
  VersusParticipant? winner;
  int roundNumber = 1;
  int matchIndex = 0;
  int matchCount = 0;
  int _playedMatches = 0;

  bool get isCompleted => winner != null || (_participants.length <= 1 && left == null);
  List<VersusParticipant> get participants => List.unmodifiable(_participants);

  /// Total matches of the whole tournament (n - 1 for n participants).
  int get totalMatches => _participants.isEmpty ? 0 : _participants.length - 1;
  int get playedMatches => _playedMatches;

  String get statusText =>
      isCompleted ? 'Tournament complete' : 'Round $roundNumber · Match $matchIndex of $matchCount';

  void restart([List<VersusParticipant>? participants]) {
    final source = participants ?? _participants;
    final seen = <String>{};
    _participants = [
      for (final participant in source)
        if (seen.add(participant.path)) participant,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final participant in _participants) {
      participant
        ..bestRoundReached = 1
        ..isWinner = false;
    }

    results.clear();
    left = null;
    right = null;
    winner = null;
    _playedMatches = 0;
    _active = [..._participants];
    _prepareRound(1);
    notifyListeners();
  }

  void chooseLeft() => _choose(left, right);
  void chooseRight() => _choose(right, left);

  void _choose(VersusParticipant? chosen, VersusParticipant? other) {
    if (chosen == null || isCompleted) {
      return;
    }

    chosen.bestRoundReached = max(chosen.bestRoundReached, roundNumber + 1);
    if (other != null) {
      other.bestRoundReached = max(other.bestRoundReached, roundNumber);
    }

    _playedMatches++;
    _roundWinners.add(chosen);
    _showNextMatch();
    notifyListeners();
  }

  void _prepareRound(int number) {
    roundNumber = number;
    left = null;
    right = null;

    if (_active.length <= 1) {
      _complete(_active.firstOrNull);
      return;
    }

    final ordered = [..._active]
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

    var entrants = 1;
    while (entrants * 2 <= ordered.length) {
      entrants *= 2;
    }

    _roundByes = ordered.skip(entrants).toList();
    for (final bye in _roundByes) {
      bye.bestRoundReached = max(bye.bestRoundReached, number + 1);
    }

    final roundEntrants = ordered.take(entrants).toList()..shuffle(_random);
    _roundWinners = [];
    _roundMatches.clear();
    for (var index = 0; index < roundEntrants.length; index += 2) {
      _roundMatches.add((roundEntrants[index], roundEntrants[index + 1]));
    }

    matchCount = _roundMatches.length;
    matchIndex = 0;
    _showNextMatch();
  }

  void _showNextMatch() {
    if (_roundMatches.isEmpty) {
      _active = [..._roundByes, ..._roundWinners];
      _prepareRound(roundNumber + 1);
      return;
    }

    matchIndex++;
    final (nextLeft, nextRight) = _roundMatches.removeFirst();
    left = nextLeft;
    right = nextRight;
  }

  void _complete(VersusParticipant? champion) {
    winner = champion;
    champion?.isWinner = true;
    results
      ..clear()
      ..addAll(
        [..._participants]..sort((a, b) {
          if (a.isWinner != b.isWinner) {
            return a.isWinner ? -1 : 1;
          }

          final byRound = b.bestRoundReached.compareTo(a.bestRoundReached);
          if (byRound != 0) {
            return byRound;
          }

          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime != 0 ? byTime : a.path.toLowerCase().compareTo(b.path.toLowerCase());
        }),
      );
  }
}
