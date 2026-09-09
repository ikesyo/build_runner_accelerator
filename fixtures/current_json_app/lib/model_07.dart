import 'package:json_annotation/json_annotation.dart';

part 'model_07.g.dart';

@JsonSerializable()
class Model07 {
  Model07({required this.id, required this.displayName});

  factory Model07.fromJson(Map<String, dynamic> json) =>
      _$Model07FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model07ToJson(this);
}

// baseline-marker: base
