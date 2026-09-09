import 'package:json_annotation/json_annotation.dart';

part 'model_10.g.dart';

@JsonSerializable()
class Model10 {
  Model10({required this.id, required this.displayName});

  factory Model10.fromJson(Map<String, dynamic> json) =>
      _$Model10FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model10ToJson(this);
}

// baseline-marker: base
