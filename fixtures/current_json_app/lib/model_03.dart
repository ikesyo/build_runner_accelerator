import 'package:json_annotation/json_annotation.dart';

part 'model_03.g.dart';

@JsonSerializable()
class Model03 {
  Model03({required this.id, required this.displayName});

  factory Model03.fromJson(Map<String, dynamic> json) =>
      _$Model03FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model03ToJson(this);
}

// baseline-marker: base
