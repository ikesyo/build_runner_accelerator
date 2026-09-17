library drift_analyzer_app;

import 'package:drift/drift.dart';

@DriftDatabase(include: {'schema.drift'})
class AppDatabase {
  AppDatabase();
}
