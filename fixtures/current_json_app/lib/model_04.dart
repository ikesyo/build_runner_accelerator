import 'package:json_annotation/json_annotation.dart';

part 'model_04.g.dart';

@JsonSerializable()
class Model04 {
  Model04({required this.id, required this.displayName});

  factory Model04.fromJson(Map<String, dynamic> json) =>
      _$Model04FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model04ToJson(this);
}

// baseline-marker: base
