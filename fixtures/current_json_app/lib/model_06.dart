import 'package:json_annotation/json_annotation.dart';

part 'model_06.g.dart';

@JsonSerializable()
class Model06 {
  Model06({required this.id, required this.displayName});

  factory Model06.fromJson(Map<String, dynamic> json) =>
      _$Model06FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model06ToJson(this);
}

// baseline-marker: base
