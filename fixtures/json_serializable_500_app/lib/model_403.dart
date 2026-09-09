import 'package:json_annotation/json_annotation.dart';

part 'model_403.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model403 {
  const Model403({required this.id, required this.value});

  final int id;
  final String value;

  factory Model403.fromJson(Map<String, dynamic> json) =>
      _$Model403FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model403ToJson(this);
}
